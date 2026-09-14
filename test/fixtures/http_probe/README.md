These are public, disposable TLS test keys. Never use them outside tests or add
this CA to the system trust store. The fixture trusts the CA only in its own
`SecurityContext` and still checks the hostname and certificate chain.

`test/helpers/probe_certificates.dart` uses OpenSSL to create a 30-day leaf in a
temporary directory for each test suite. This avoids a checked-in leaf expiring
and respects macOS certificate lifetime limits. macOS CI/Command Line Tools
provide OpenSSL; Windows uses the copy installed with Git for Windows.

The CA expires in 2126. Neither certificate generation nor the HTTP tests make
external network requests. The CONNECT fixture ignores the requested destination
and forwards only to its own loopback TLS endpoint.
