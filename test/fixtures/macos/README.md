These six golden files cover keqrnel (xray), Mihomo, and AWG sessions in Proxy
and TUN mode. All node addresses, keys, passwords, API tokens, and network
identifiers are synthetic test data. No live credentials or system snapshots
are stored here.

The test compares the complete parsed configuration, preserving rule order.
Only the host-specific test executable and bundled-core paths are normalized
to the installed KEQDIS bundle. Nested JSON configurations are expanded for
review; wireproxy configuration remains an INI string.

Regenerate intentionally with `UPDATE_MACOS_GOLDENS=1 flutter test
test/tunnel/macos_session_contract_test.dart`. Review every changed fixture.
Setting `KEQDIS_MACOS_FIXTURE_DIR` additionally exports real wire-format
requests for the read-only native `keqdis-network-tests --validate-request`
command; neither test starts a core or changes system networking.
