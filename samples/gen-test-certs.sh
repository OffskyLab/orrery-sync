#!/usr/bin/env bash
# Generate test certificates for orrery-sync mTLS.
# FOR TESTING ONLY — do not use in production.
#
# Usage:
#   ./gen-test-certs.sh              # generates in ./certs/
#   ./gen-test-certs.sh /path/to/dir # generates in specified dir
#
# Output:
#   ca.pem / ca-key.pem           — shared CA (distribute to all peers)
#   node-a.pem / node-a-key.pem   — identity cert for peer A
#   node-b.pem / node-b-key.pem   — identity cert for peer B
#
# Then start daemons with:
#   orrery-sync daemon --port 9527 --tls-ca certs/ca.pem --tls-cert certs/node-a.pem --tls-key certs/node-a-key.pem
#   orrery-sync daemon --port 9528 --tls-ca certs/ca.pem --tls-cert certs/node-b.pem --tls-key certs/node-b-key.pem

set -euo pipefail

OUTDIR="${1:-./certs}"
DAYS=365

mkdir -p "$OUTDIR"

echo "==> Generating CA..."
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout "$OUTDIR/ca-key.pem" -out "$OUTDIR/ca.pem" \
  -days "$DAYS" -nodes -subj "/CN=orrery-sync-ca" 2>/dev/null

sign_node() {
  local name="$1"
  echo "==> Generating node cert: $name"
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$OUTDIR/${name}-key.pem" -out "$OUTDIR/${name}-csr.pem" \
    -nodes -subj "/CN=orrery-sync-${name}" 2>/dev/null

  openssl x509 -req -in "$OUTDIR/${name}-csr.pem" \
    -CA "$OUTDIR/ca.pem" -CAkey "$OUTDIR/ca-key.pem" \
    -CAcreateserial -out "$OUTDIR/${name}.pem" \
    -days "$DAYS" 2>/dev/null

  rm -f "$OUTDIR/${name}-csr.pem"
}

sign_node "node-a"
sign_node "node-b"

rm -f "$OUTDIR/ca.srl"

echo ""
echo "Done. Certificates in $OUTDIR/"
ls -1 "$OUTDIR"/*.pem
