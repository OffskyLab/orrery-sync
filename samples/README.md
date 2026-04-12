# Samples

## mTLS Test Certificates

Generate test certificates for two peers:

```bash
./gen-test-certs.sh
# outputs to ./certs/
```

### Start daemons with mTLS

```bash
# Peer A
orrery-sync daemon --port 9527 \
  --tls-ca certs/ca.pem \
  --tls-cert certs/node-a.pem \
  --tls-key certs/node-a-key.pem

# Peer B
orrery-sync daemon --port 9528 \
  --tls-ca certs/ca.pem \
  --tls-cert certs/node-b.pem \
  --tls-key certs/node-b-key.pem
```

Both peers share the same CA. Any peer presenting a certificate not signed by this CA is rejected at the TLS handshake.

### Without mTLS

Omit the `--tls-*` flags to run in plaintext mode:

```bash
orrery-sync daemon --port 9527
```
