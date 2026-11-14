## Summary

<!-- What does this change and why? -->

## Testing

- [ ] `swift build` and `swift test --skip IntegrationTests` pass
- [ ] Integration tests run against the PostgreSQL versions this touches (`scripts/pg-up.sh`, `CCINNPSQL_IT=1`)
- [ ] Pooler/extension suites run if connection or catalog code changed (`scripts/pooler-up.sh`, `scripts/extensions-up.sh`)
- [ ] UI changes checked in light and dark appearance

## Notes

<!-- PostgreSQL versions affected, screenshots, follow-ups. Update CHANGELOG.md under "Unreleased". -->
