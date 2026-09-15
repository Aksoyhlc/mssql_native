# Capabilities — mssql_native

Driver defaults and hard limits. ORM SQL-language capabilities are in
[`mssql_orm/doc/CAPABILITIES.md`](https://github.com/Aksoyhlc/mssql_orm/blob/main/doc/CAPABILITIES.md).

| Setting | Default | Opt-in |
|---|---|---|
| Login | SQL Server user name and password | `DOMAIN\user` + password (NTLMv2, every platform); `integratedSecurity` (SSPI, Windows only) |
| Decimal | `MssqlDecimalMode.exact` (`MssqlDecimal`) | `text`, `doublePrecision` |
| Encryption | `MssqlEncryption.off` | `request`, `require`, `strict` |
| Certificate trust | none until `initialize(tls: …)` | PEM CA, `system()`, insecure |
| Retry | `MssqlRetryPolicy.never` | explicit policy; never for procedures / arbitrary SQL / writes because returning rows is not “a read” |
| Isolation after release | `READ COMMITTED` (baseline) | per-transaction level, restored |

Trust is process-wide. Plaintext needs no trust configuration. A connection
that explicitly asks for `require` or `strict` without configured trust
**fails closed**. There is no silent insecure fallback.

Integrated security is refused when a configuration that asks for it is
validated off Windows: the packaged FreeTDS carries SSPI on Windows and no
Kerberos backend elsewhere. A domain login with its password works from every
platform and is what the refusal names.

MARS is not used: one active query per connection. Named SQL Browser
instances (`host\INSTANCE`) are refused; give `host,port`.

Packaged platforms and the web/32-bit refusals:
[README · Platform support](../README.md#platform-support). Encryption in
detail: [TLS.md](TLS.md). Signatures: [API.md](API.md).
