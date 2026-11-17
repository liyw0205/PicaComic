# Remote Source Fixtures

These JavaScript files are normalized snapshots of `liyw0205/pica_configs` at commit
`0ca403bd05dc09e0eea11b32fa6a28800f1ca044`. The test loads each script with
`ComicSourceParser` and executes it through QuickJS; HTTP calls are handled by
an in-memory Dio adapter. The `ikmmh.js` fixture normalizes CRLF to LF and
strips trailing spaces from one otherwise empty upstream line; its JavaScript
behavior is unchanged.

The copied MIT license is retained in `LICENSE`. Refresh the script snapshots,
the versions and required request paths in `test/remote_source_fixture_test.dart`
when updating the pinned source commit.

SHA-256:

- `baozi.js`: `f1ae4c293a9772a9e81f2fd61e8e9ca03eead73c7bc6565a5f82b759ac375448`
- `copy_manga.js`: `09920dc8d5f66585f0283a883b634c2b8a1da38d9be50ad99638925f9266cc9b`
- `ikmmh.js`: `6df2c642fc84e0e32aacc71437c63e8e9b2122c40f5b4c3a5d0af4aed38ab502`
- `komiic.js`: `5be1957ab5c0b6208c649467c320553b41b651ed18e02faabaf64764fddee5cb`
