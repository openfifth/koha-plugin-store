# ToDo

## Koha

- Thumbnail display ✔
- Search by plugin Name and Description
- Sort by plugin Name, Author
- Reviews
- Add Star ratings
- Add Translations
- Add update notifications
- Add detail about plugin hooks used

## Store

- Clean up development views ✔
  - User list on home page ✔
  - Password hashes in user lists display ✔
- Documentation page including
  - How to package your plugins to include Icons/Thumbnails
- Add storage and API for plugin star ratings
- Add storage and API for plugin reviews
- Add GPG signature checks for plugins ✔ (informational only — `gpg_signed_tag`
  check records whether a release tag is GPG-signed, see
  `docs/CERTIFICATION.md`; doesn't gate publish or certification tier yet)
- Add a badge system for community rating of plugins
- Add authentication via GitHub ✔ (OAuth login, see `DEVELOPMENT.md`)
