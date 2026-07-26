# WSS loopback PKI

These certificates and private keys are test fixtures only. Never install the
root as a system trust anchor or use these keys in a deployed service. The
loopback harness supplies `root-ca.pem` only through the fixture client's
`WS_Options.ca_file` setting.

SHA-256 fingerprints:

- Root CA: `96:3C:A7:46:20:D0:25:91:C1:77:7A:2E:F2:A6:7D:E9:EF:71:49:29:6E:8A:9F:4E:4C:F3:62:F5:9B:43:76:72`
- Localhost leaf: `4E:4A:F7:D3:61:36:D6:9A:D1:F7:D0:37:A3:9F:FD:95:9A:EB:D0:ED:0C:03:CC:61:B7:35:28:70:EE:BA:12:67`

The harness verifies a trusted localhost chain, an untrusted chain, hostname
mismatch, valid WSS upgrade and framing, malformed upgrade, and clean teardown.
