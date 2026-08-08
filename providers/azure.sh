#!/usr/bin/env bash
# provider: azure - agentfleet owns the machines.
#
# Creates Ubuntu VMs from providers/azure-cloud-init.yaml, narrows the SSH
# firewall rule to your current egress IP, and gives each machine a managed
# identity so nothing running on it ever needs an interactive cloud login.
#
# Sourced by af_provider_load, so AF_* and af_* are already available here.

af_need az

: "${AF_AZ_GROUP:=$AF_NAME}"
: "${AF_AZ_REGION:=westus2}"
: "${AF_AZ_SIZE:=Standard_D8as_v5}"
: "${AF_AZ_IMAGE:=Canonical:ubuntu-24_04-lts:server:latest}"
: "${AF_AZ_DISK_GB:=200}"
: "${AF_AZ_LOCK_SSH:=1}"
: "${AF_AZ_IP_URL:=https://api.ipify.org}"
: "${AF_AZ_IDENTITY_ROLE:=Reader}"

# Azure demands an admin account at create time; the cloud-init then creates the
# real, path-mirrored one. The two must not collide.
AZ_BOOTSTRAP_USER=afbootstrap
[ "$AF_USER" != "$AZ_BOOTSTRAP_USER" ] || af_die "AF_USER cannot be '$AZ_BOOTSTRAP_USER': that name is taken by the throwaway admin account azure requires at create time"

# `az vm create --nsg-rule SSH` generates these two names and offers no way to
# choose them, so agentfleet has to know them to narrow the rule afterwards.
AZ_SSH_RULE=default-allow-ssh
az_nsg_name() { printf '%sNSG' "$1"; }

# ---------------------------------------------------------------- helpers

az_egress_ip() {
  af_need curl
  local ip
  ip="$(curl -fsS --max-time 10 "$AF_AZ_IP_URL" 2>/dev/null | tr -d '[:space:]')" || true
  case "$ip" in
    ""|*[!0-9a-fA-F.:]*) return 1 ;;
  esac
  printf '%s' "$ip"
}

az_cidr() {
  case "$1" in
    *:*) printf '%s/128' "$1" ;;
    *)   printf '%s/32' "$1" ;;
  esac
}

# The machines get the operator's timezone: an agent's timestamps are read by a
# human, and reading UTC logs against a local calendar is how you mis-file work.
az_local_timezone() {
  local tz=""
  if [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime)"
    case "$tz" in
      */zoneinfo/*) tz="${tz#*/zoneinfo/}" ;;
      *) tz="" ;;
    esac
  fi
  [ -n "$tz" ] || tz="UTC"
  printf '%s' "$tz"
}

# sed replacement text treats backslash and & specially. Escaping happens here;
# rejecting the delimiter happens in the caller, because a die inside a command
# substitution only kills the substitution and would leave the value empty.
az_sed_value() { printf '%s' "$1" | sed 's/[\\&]/\\&/g'; }

az_render_cloud_init() {
  local host="$1" out="$2"
  local tmpl="$AF_DIR/providers/azure-cloud-init.yaml"
  [ -f "$tmpl" ] || af_die "missing cloud-init template: $tmpl"
  # The operator's own public key goes in at render time. No key material of any
  # kind belongs in a file that ships with the tool.
  [ -f "$AF_KEY.pub" ] || af_die "no public key at $AF_KEY.pub - create the pair with: ssh-keygen -t ed25519 -f $AF_KEY"

  local pubraw tzraw v
  pubraw="$(cat "$AF_KEY.pub")"
  tzraw="$(az_local_timezone)"
  # | is the sed delimiter below. Refuse such a value rather than render YAML
  # that is subtly wrong and only shows up as a machine you cannot log into.
  for v in "$AF_USER" "$AF_HOME" "$pubraw" "$tzraw"; do
    case "$v" in *"|"*) af_die "cannot template a value containing '|': $v" ;; esac
    [ -n "$v" ] || af_die "cannot render cloud-init for $host: AF_USER, AF_HOME, the public key and the timezone must all be set"
  done

  local user home pub tz ts
  user="$(az_sed_value "$AF_USER")"
  home="$(az_sed_value "$AF_HOME")"
  pub="$(az_sed_value "$pubraw")"
  tz="$(az_sed_value "$tzraw")"
  if [ "$AF_TAILNET" = off ]; then ts=0; else ts=1; fi

  mkdir -p "$AF_CACHE"
  sed -e "s|{{AF_USER}}|$user|g" \
      -e "s|{{AF_HOME}}|$home|g" \
      -e "s|{{AF_PUBKEY}}|$pub|g" \
      -e "s|{{AF_TIMEZONE}}|$tz|g" \
      -e "s|{{AF_TAILSCALE}}|$ts|g" \
      "$tmpl" > "$out" || af_die "could not render cloud-init for $host into $out"
  # A placeholder that survived means a machine boots without its ssh key or
  # with a broken user block, and you find out twenty minutes later over a
  # connection that never opens. Refuse now instead.
  local left
  left="$(grep -o '{{[A-Z_][A-Z_]*}}' "$out" | sort -u | tr '\n' ' ')" || true
  [ -z "$left" ] || af_die "cloud-init for $host still has unsubstituted placeholders: $left"
}

# ---------------------------------------------------------------- interface

provider_list() {
  local out
  if out="$(az vm list -g "$AF_AZ_GROUP" --query '[].name' -o tsv 2>&1)"; then
    printf '%s\n' "$out" | grep -v '^$' || true
    return 0
  fi
  # An empty fleet and a broken cloud login must not look the same. Only "the
  # group does not exist yet" is allowed to mean "no machines".
  case "$out" in
    *ResourceGroupNotFound*|*"could not be found"*) return 0 ;;
  esac
  af_die "azure: could not list machines in $AF_AZ_GROUP: $out"
}

provider_addr() {
  local host="${1:?provider_addr <host>}" ip
  ip="$(az vm list-ip-addresses -g "$AF_AZ_GROUP" -n "$host" \
        --query '[0].virtualMachine.network.publicIpAddresses[0].ipAddress' \
        -o tsv 2>/dev/null)" || return 1
  [ -n "$ip" ] && [ "$ip" != None ] || return 1
  printf '%s' "$ip"
}

provider_create() {
  local host="${1:?provider_create <host> [size]}" size="${2:-$AF_AZ_SIZE}"

  # Resolve the egress IP BEFORE creating anything. Azure opens port 22 to the
  # entire internet during create and we narrow it a second later, so a machine
  # we cannot lock is a machine we refuse to create.
  local myip=""
  if [ "$AF_AZ_LOCK_SSH" = 1 ]; then
    myip="$(az_egress_ip)" || af_die "could not determine your public IP via $AF_AZ_IP_URL, so the ssh rule could not be locked.
  Fix the lookup (AF_AZ_IP_URL), or set AF_AZ_LOCK_SSH=0 to accept an ssh port open to the internet."
  fi

  # Create the group ONLY when it is missing. `az group create` fails when the
  # group already exists in a different region, and that failure would block the
  # one trick that gets you past a per-region CPU quota: a machine does not have
  # to live in its group's region, so a second region needs no second group.
  az group show -n "$AF_AZ_GROUP" -o none 2>/dev/null || \
    az group create -n "$AF_AZ_GROUP" -l "$AF_AZ_REGION" -o none

  local ci="$AF_CACHE/cloud-init-$host.yaml"
  az_render_cloud_init "$host" "$ci"

  af_log "[azure] creating $host ($size, $AF_AZ_REGION) in $AF_AZ_GROUP"
  local ip
  # --location is explicit so AF_AZ_REGION actually decides where the machine
  # lands; left implicit it silently inherits the group's region.
  # A Standard-SKU public IP is static, so the address survives stop/start and
  # anything caching it (generated ssh config) stays correct.
  ip="$(az vm create -g "$AF_AZ_GROUP" -n "$host" \
        --location "$AF_AZ_REGION" \
        --image "$AF_AZ_IMAGE" --size "$size" \
        --admin-username "$AZ_BOOTSTRAP_USER" --ssh-key-values "$AF_KEY.pub" \
        --os-disk-size-gb "$AF_AZ_DISK_GB" --public-ip-sku Standard --nsg-rule SSH \
        --assign-identity \
        --custom-data "$ci" \
        --query publicIpAddress -o tsv)" || af_die "azure: creating $host failed"
  [ -n "$ip" ] && [ "$ip" != None ] || af_die "azure: $host was created without a public IP address"

  if [ -n "$myip" ]; then
    local cidr; cidr="$(az_cidr "$myip")"
    az network nsg rule update -g "$AF_AZ_GROUP" --nsg-name "$(az_nsg_name "$host")" \
      -n "$AZ_SSH_RULE" --source-address-prefixes "$cidr" -o none \
      || af_die "created $host but FAILED to narrow its ssh rule - port 22 is open to the internet right now. Retry with: agentfleet unlock $host (or destroy the machine)."
    af_log "[azure] $host ssh locked to $cidr"
  else
    af_warn "AF_AZ_LOCK_SSH=0: port 22 on $host accepts connections from any address"
  fi

  # Managed identity instead of a copied credential: `az login --identity` on
  # the machine means no interactive cloud login ever happens there, which is
  # what makes an unattended provision possible at all.
  local pid sub
  pid="$(az vm show -g "$AF_AZ_GROUP" -n "$host" --query identity.principalId -o tsv 2>/dev/null || true)"
  if [ -n "$pid" ] && [ "$pid" != None ]; then
    sub="$(az account show --query id -o tsv)"
    az role assignment create --assignee "$pid" --role "$AF_AZ_IDENTITY_ROLE" \
      --scope "/subscriptions/$sub/resourceGroups/$AF_AZ_GROUP" -o none 2>/dev/null \
      || af_warn "could not grant '$AF_AZ_IDENTITY_ROLE' on $AF_AZ_GROUP to $host's identity (that needs Owner or User Access Administrator). The machine boots fine, but 'az login --identity' on it will have no permissions."
  else
    af_warn "$host has no managed identity, so 'az login --identity' will not work there"
  fi

  printf '%s\n' "$ip"
}

provider_start() {
  local host="${1:?provider_start <host>}"
  az vm start -g "$AF_AZ_GROUP" -n "$host" -o none || af_die "azure: could not start $host"
  af_log "[azure] $host started"
}

provider_stop() {
  local host="${1:?provider_stop <host> [--delete]}"
  if [ "${2:-}" = --delete ]; then
    az vm delete -g "$AF_AZ_GROUP" -n "$host" --yes -o none || af_die "azure: could not delete $host"
    # `az vm delete` removes the VM object only. The disk, NIC, public IP and
    # NSG are separate resources and keep billing until you remove them too.
    af_log "[azure] $host DELETED - its disk, NIC, public IP and NSG remain: az resource list -g $AF_AZ_GROUP -o table"
  else
    az vm deallocate -g "$AF_AZ_GROUP" -n "$host" -o none || af_die "azure: could not deallocate $host"
    af_log "[azure] $host deallocated - compute billing stopped, disk kept"
  fi
}

# Not part of the five-function interface: the documented recovery path for the
# SSH lock. Change wifi, get a new lease from your ISP, work from a train, and
# every machine becomes unreachable over its public IP while being perfectly
# healthy - that has stranded a whole fleet before. This re-points the rule at
# wherever you are now. Over a tailnet you never notice, which is the reason
# AF_TAILNET=auto is the recommended setting.
provider_unlock() {
  local myip cidr host hosts rc=0
  myip="$(az_egress_ip)" || af_die "could not determine your public IP via $AF_AZ_IP_URL"
  cidr="$(az_cidr "$myip")"
  if [ $# -gt 0 ]; then hosts="$*"; else hosts="$(provider_list)"; fi
  [ -n "$hosts" ] || af_die "no machines in $AF_AZ_GROUP to unlock"
  for host in $hosts; do
    if az network nsg rule update -g "$AF_AZ_GROUP" --nsg-name "$(az_nsg_name "$host")" \
         -n "$AZ_SSH_RULE" --source-address-prefixes "$cidr" -o none 2>/dev/null; then
      af_log "[azure] $host ssh now allowed from $cidr"
    else
      af_warn "$host: no '$AZ_SSH_RULE' rule on $(az_nsg_name "$host") - created outside agentfleet?"
      rc=1
    fi
  done
  return $rc
}
