# Interface localisation

The viewer now treats visible interface wording as locale data instead of embedding every phrase directly in the views.

This is still an extraction and staging pass:

- English (`en`) is the source catalogue.
- Every staged locale has an explicit key-for-key placeholder catalogue.
- Placeholder values remain English until a human translator replaces them.
- Literary Chinese (`lzh`) retains the small amount of reviewed Literary Chinese wording already present.
- No machine translation has been added.
- Crowdin is not connected yet.
- No routes have changed.
- Corpus text, metadata values, database values, paths, and stable identifiers are not locale strings.

## Locale codes

The complete staged set is defined once in `config/interface_locales.rb`:

```text
en   English source

ja   Japanese
ryu  Okinawan
vie  Vietnamese
ko   Korean
jje  Jeju
cmn  Mandarin
lzh  Literary Chinese
yue  Cantonese
nan  Hokkien
wuu  Shanghainese
cjy  Jin Chinese
hak  Hakka Chinese
hsn  Xiang Chinese
gan  Gan Chinese
czh  Hui Chinese
cnp  Northern Pinghua
csp  Southern Pinghua
dng  Dungan
zha  Zhuang
ru   Russian
```

Only `en` and `lzh` are currently exposed by the site language button. The other catalogues are staged but hidden until humans have translated and reviewed them. This prevents the public interface from advertising twenty languages that still display English.

`ru` is the project code used for Russian.

## Files translators edit

Each locale mirrors the English feature files:

```text
config/locales/<code>/common.yml
config/locales/<code>/corpus_viewer.yml
config/locales/<code>/home.yml
config/locales/<code>/pronunciations.yml
config/locales/<code>/pronunciation_data.yml
config/locales/<code>/site.yml
config/locales/<code>/view_options.yml
```

The target files begin with:

```yaml
# PLACEHOLDER CATALOGUE: translate values only; do not rename keys.
```

A view requests a stable key:

```erb
<%= t("corpus_viewer.toolbar.theme") %>
```

English supplies the source wording:

```yaml
en:
  corpus_viewer:
    toolbar:
      theme: Theme
```

A translator edits only the value in their target file:

```yaml
ja:
  corpus_viewer:
    toolbar:
      theme: Theme
```

The second `Theme` is deliberately still English at this stage. The key `corpus_viewer.toolbar.theme` must not be renamed.

## Pronunciation and topolect names

Pronunciation labels have a larger generated catalogue in `pronunciation_data.yml`. It contains:

- labels for registered pronunciation fields;
- second-level pronunciation groups and topolect names;
- locations where the registry supplies one;
- ruby-source labels;
- short annotations such as `Accent class`.

The pronunciation registry already stores paired values such as:

```yaml
variety_label: 湖口
variety_label_en: Hukou
```

These are canonical data labels, not speculative translations. The generated locale catalogues therefore contain:

```yaml
# config/locales/en/pronunciation_data.yml
label: Hukou
```

```yaml
# config/locales/lzh/pronunciation_data.yml
label: 湖口
```

The Literary Chinese value is copied verbatim from the stored Chinese field. It is not independently reworded. The same applies to ruby labels such as `湖口 — IPA`.

Other staged languages initially receive the English value as a visible placeholder:

```yaml
# config/locales/ru/pronunciation_data.yml
label: Hukou
```

A Russian translator can later replace that value without changing the registry key or the pronunciation data itself.

## Locale selection

The existing `POST /preferences` endpoint stores the selected locale in the session. `ApplicationController` wraps each request with `I18n.with_locale`, so one visitor's setting cannot leak into another request.

`InterfaceLocales::ALL` lists the locales Rails accepts. `InterfaceLocales::SELECTABLE` lists the locales currently exposed by the interface. At present:

```ruby
ALL = %i[en ja ryu vie ko jje cmn lzh yue nan wuu cjy hak hsn gan czh cnp csp dng zha ru]
SELECTABLE = %i[en lzh]
```

## Validation

Run:

```bash
ruby script/validate_locales.rb
```

The validator checks that:

- every YAML file parses;
- every staged locale exists;
- every extracted English key exists in every target catalogue;
- target catalogues do not invent keys with no English source;
- interpolation variables such as `%{count}` are preserved;
- every static `t("...")` call in an ERB view has an English source value.

## Adding new interface text

1. Add the English key under `config/locales/en/`.
2. Replace the hardcoded wording in the view with `t("the.key")`.
3. Run:

```bash
ruby script/sync_locale_placeholders.rb
```

This adds missing keys to every target without overwriting existing human translations.

4. Run the validator.

The general placeholder synchroniser deliberately leaves `pronunciation_data.yml` alone because that file is generated from the pronunciation registry.

## Updating pronunciation catalogues

After adding or changing pronunciation registry entries, run:

```bash
ruby script/rebuild_pronunciation_locale_catalogues.rb
```

This reads:

```text
config/pronunciations.yml
config/pronunciation_datasets.yml
```

It then:

- rebuilds the English pronunciation source catalogue;
- supplies Chinese defaults for new Literary Chinese topolect and ruby labels;
- supplies English defaults for new keys in other target locales;
- preserves existing human target-language values where the key already exists.

Then run `ruby script/validate_locales.rb`.

## Hardcoded-text inventory

Run:

```bash
ruby script/i18n_hardcoded_audit.rb
```

This reports likely visible strings that have not yet been extracted. It is an inventory, not an automatic replacement tool, and will include some false positives.

The current extraction still does not cover the entire application. Major remaining areas include Stimulus-generated messages, FieldLens labels outside the pronunciation registry, the ticket dashboard, tools, textbook pages, and longer homepage prose.

## Crowdin later

The repository should eventually upload only the English source files and receive reviewed target files back through a translation branch.

Crowdin distinguishes two-letter codes, three-letter codes, and locale identifiers when constructing export paths. This project intentionally uses the exact internal codes listed above, so the eventual `crowdin.yml` should map Crowdin's language identifiers onto these folder names rather than assuming one export placeholder will match every code automatically. Rare varieties may need Crowdin custom-language entries.

## Canonical Chinese pronunciation names

The pronunciation registry stores canonical Chinese names for topolects and source locations alongside English display labels. The following Sinitic interface locales use those Chinese names as their initial pronunciation-data catalogue:

`lzh`, `yue`, `nan`, `wuu`, `cjy`, `hak`, `hsn`, `gan`, `czh`, `cnp`, and `csp`.

This only supplies a sensible starting value. A human translator may replace any individual label in that locale file, and rebuilding the catalogue preserves existing human edits while giving new registry entries their canonical Chinese labels.
