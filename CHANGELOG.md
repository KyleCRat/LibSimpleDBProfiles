# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- Add the `initialProfile` constructor option: keep `mostSpecific` as the
  compatible default, or choose any permanent profile type for characters
  without a valid saved selection. Preserve existing choices and handle
  delayed specialization identity without overwriting user selections.

## 1.0.0 - 2026-08-10

- Implement the initial `LibSimpleDBProfiles-1.0` family on
  `LibSimpleDB-2.0`.
- Add permanent and user profiles with one-time specificity selection and a
  stable active database.
- Add normalized multilingual user names, lifecycle callbacks, exact
  administration IDs, offline character management, and explicit reset versus
  forget behavior.
- Add stateless consumer Migration objects with staged version-step commits.
- Add mixed-embed compatible prototype upgrades and a Lua 5.1 test suite.
- Reconcile specialization identity after addon load so new characters can
  inherit existing Specialization profiles and stored Specialization selections
  survive reload without constructor failure.
