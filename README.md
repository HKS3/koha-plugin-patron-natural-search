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

## Build

From this directory:

```sh
zip -r koha-plugin-patron-natural-search-v0.1.0.kpz Koha README.md
```
