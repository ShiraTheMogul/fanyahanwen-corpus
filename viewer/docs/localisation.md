# Interface localisation

The viewer treats visible interface wording as locale data instead of embedding every phrase directly in views and Stimulus controllers.

Current rules:

- English (`en`) is the source catalogue.
- Every staged locale has an explicit key-for-key placeholder catalogue.
- Placeholder values remain English until a human translator replaces them.
- Literary Chinese (`lzh`) contains the reviewed translation completed so far; newly extracted keys appear as English placeholders until reviewed.
- No machine translation has been added.
- Crowdin is not connected yet.
- No routes have changed.
- Corpus text, metadata values, database values, paths, bibliographic records, and stable identifiers are not locale strings.

## Locale registry and visibility

The complete staged set is defined once in `config/interface_locales.rb`.

Each locale has a status:

```ruby
lzh: { native_name: "文言", status: :public }
jje: { native_name: "제주어", status: :hidden }
```

- `:public` means the locale may be selected by a request.
- `:hidden` means its catalogue exists for translators, but visitors cannot activate it.

The selector itself has a separate master switch:

```ruby
SELECTOR_VISIBLE = false
```

This is deliberately `false` while the newly extracted Literary Chinese fields are being completed. When the interface is ready for visitors, changing it to `true` reveals the prepared dropdown. It does not require a route change.

Only `en` and `lzh` are currently public. Hidden placeholder locales such as Jeju are rejected by the preferences controller even if somebody manually constructs a request.

## Staged locale codes

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

## Files translators edit

Each locale mirrors the English feature files:

```text
config/locales/<code>/common.yml
config/locales/<code>/corpus_viewer.yml
config/locales/<code>/home.yml
config/locales/<code>/javascript.yml
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

A translator edits only the value in their target file. The key must not be renamed.

## Homepage and editorial prose

Homepage headings, explanatory paragraphs, feature lists, submission controls, daily-reading chrome, and corpus-activity pages now use `home.yml`.

Canonical records are intentionally left outside Crowdin:

- publication citations;
- bibliographic references;
- dictionary titles;
- corpus titles, author names, paths, and metadata values.

Those blocks use `i18n-audit-ignore` markers so the audit does not repeatedly report content which should remain canonical.

## JavaScript-generated interface text

Stimulus cannot call Rails view helpers after a page has loaded. The layout therefore exports the active locale's `javascript` namespace as inert JSON:

```erb
<%= render "layouts/javascript_translations" %>
```

Stimulus controllers use the small helper in `app/javascript/i18n.js`:

```javascript
import { t } from "i18n"

statusTarget.textContent = t("corpus_submission.submitting")
```

The helper performs lookup and `%{variable}` interpolation. Rails YAML remains the only translation catalogue; Crowdin will not need a separate JSON source.

## Pronunciation and topolect names

Pronunciation labels have a larger generated catalogue in `pronunciation_data.yml`. It contains registered pronunciation-field labels, groups and topolect names, locations, ruby-source labels, and short annotations.

The pronunciation registry already stores paired values such as:

```yaml
variety_label: 湖口
variety_label_en: Hukou
```

These are canonical data labels, not speculative translations. The Literary Chinese catalogue therefore uses `湖口`, while English uses `Hukou`.

The following Sinitic interface locales use canonical Chinese names as their initial pronunciation-data values:

`lzh`, `yue`, `nan`, `wuu`, `cjy`, `hak`, `hsn`, `gan`, `czh`, `cnp`, and `csp`.

Human corrections remain possible, and the rebuilding script preserves existing edits.

## Validation

Run:

```bash
ruby script/validate_locales.rb
```

The validator checks that:

- every YAML file parses;
- every staged locale exists;
- visibility statuses are valid;
- the source locale is selectable;
- every extracted English key exists in every target catalogue;
- target catalogues do not invent keys with no English source;
- interpolation variables such as `%{count}` are preserved;
- every static `t("...")` call in ERB and JavaScript has an English source value.

## Adding interface text

1. Add the English key under `config/locales/en/`.
2. Replace the hardcoded wording with `t("the.key")` in ERB or `t("the.key")` from `app/javascript/i18n.js`.
3. Run:

```bash
ruby script/sync_locale_placeholders.rb
```

This adds missing keys to every target without overwriting human translations.

4. Run the validator.

The general synchroniser deliberately leaves `pronunciation_data.yml` alone because that file is generated from the pronunciation registry.

## Updating pronunciation catalogues

After adding or changing pronunciation registry entries, run:

```bash
ruby script/rebuild_pronunciation_locale_catalogues.rb
```

Then run `ruby script/validate_locales.rb`.

## Hardcoded-text inventory

Run:

```bash
ruby script/i18n_hardcoded_audit.rb
```

The audit now scans:

- ERB text and visible attributes, including multiline text;
- JavaScript string literals;
- Ruby controllers, helpers, jobs, mailers, models, presenters, services, and application libraries.

It is an itinerary, not an automatic replacement tool, and deliberately includes false positives for human review.

Canonical blocks can be excluded with paired ERB comments:

```erb
<%# i18n-audit-ignore-start: canonical bibliography %>
...
<%# i18n-audit-ignore-end %>
```

## Crowdin later

The repository should eventually upload only English source files and receive reviewed target files through a translation branch.

Crowdin distinguishes two-letter codes, three-letter codes, and locale identifiers when constructing export paths. The eventual `crowdin.yml` should map Crowdin's language identifiers onto the project's exact folder names rather than assuming one automatic code format will fit all of them.
