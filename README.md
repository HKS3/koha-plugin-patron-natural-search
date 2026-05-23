# Koha Patron Natural Search Plugin

Prototype patron search plugin for Koha using MariaDB `FULLTEXT` indexes and
`MATCH ... AGAINST` in natural language or boolean mode. It does not use
Elasticsearch.

## API

After installing and enabling the plugin:

```text
GET /api/v1/contrib/patron_natural_search/patrons?query=smith&searchfieldstype=standard
```

The route requires staff patron permissions equivalent to Koha patron search:
`borrowers.list_borrowers` or `borrowers.edit_borrowers`.

Useful query parameters:

- `query`, `q`, or `searchmember`
- `searchfieldstype` or `search_fields`
- `match_mode=natural` or `match_mode=boolean`
- `library_id` / `branchcode_filter`
- `category_id` / `categorycode_filter`
- `sort1`, `sort1_filter`, `sort2`, `sort2_filter`
- `firstletter`
- `page` / `per_page`
- `fallback_like=1` for compatibility with Koha's prefix/contains behavior

Boolean mode uses MariaDB `IN BOOLEAN MODE`, so boolean operators supported by
MariaDB can be used in the query. For example, `query=Oxf*&match_mode=boolean`
matches indexed tokens beginning with `Oxf`.

Supported field selectors include `standard`, `all`, `full_address`, `all_emails`,
`all_phones`, borrower column names, API field aliases, and `_ATTR_<code>` for
patron attributes.

`standard` searches Koha's `DefaultPatronSearchFields` plus patron attribute
types that are marked `staff_searchable` and `searched_by_default` when
`ExtendedPatronAttributes` is enabled.

## Indexes

The plugin `install` method creates a plugin-owned table named
`plugin_patron_natural_search` with a MariaDB `FULLTEXT` index on its `content`
column. The table stores field-specific and grouped patron search documents,
including `standard`, `all`, `full_address`, `all_emails`, `all_phones`,
individual borrower fields, and searchable patron attributes. The `all` group is
one denormalized document per patron containing borrower fields plus all patron
attribute code/value text, so cross-field boolean searches such as
`query=+Oxford +john*&match_mode=boolean&searchfieldstype=all` can match a name
token and an attribute token on the same patron.

The install/upgrade path rebuilds the index table. Database triggers keep the
index table synchronized when `borrowers` or `borrower_attributes` rows change.
The `uninstall` method drops only this plugin table and its triggers.

## Database size

As a rough sizing point, a KTD MariaDB test database with 100,052 patrons and
399,996 patron attributes produced 985,580 rows in
`plugin_patron_natural_search`. MariaDB reported about 160 MiB for that table,
including data and indexes:

```text
DATA_LENGTH  75.6 MiB
INDEX_LENGTH 91.7 MiB
total        159.6 MiB
```

That works out to roughly 1.6 MiB per 1,000 patrons, or about 160 MiB per
100,000 patrons for this dataset. Real installations may differ substantially
depending on how many searchable attributes exist, how long address/note fields
are, how many grouped documents are enabled, and MariaDB/InnoDB page and
FULLTEXT index behavior. Use 150-250 MiB per 100,000 patrons as a conservative
starting estimate, then measure the local data after an index rebuild.

## Build

From this directory:

```sh
./scripts/build-kpz
```

The KPZ is written to `dist/`.

GitHub Actions also builds the KPZ on pushes, pull requests, and manual
workflow runs. Tag pushes matching `v*` attach the generated KPZ to the matching
GitHub release.
