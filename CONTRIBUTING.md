# Contributing

Contributions are welcome. Keep every test and example synthetic—never include real messages, account IDs, message IDs, codes, tokens, reports, automation memory, or exported attachments.

Before opening a pull request, run:

```sh
swift build
swift run MailBridgeSelfTest
python3 -m unittest Tests/integration_test.py
```

Changes that expand MailBridge's mutation surface—sending, moving, deleting, changing read state, or silently retrying writes—will not be accepted. Security reports containing sensitive details should be sent privately to the repository owner rather than filed as public issues.
