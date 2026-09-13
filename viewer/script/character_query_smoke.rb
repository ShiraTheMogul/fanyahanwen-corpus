# frozen_string_literal: true

# Smoke test for the character constraint query.
#
#   cd viewer
#   bin/rails runner script/character_query_smoke.rb
#
# Exercises every path that cannot be checked without booting Rails: the
# slot-index build (both the character_properties path and the table-backed
# one), tone binding, the picker tree, the homophone seeker, component and IDS
# lookups, the graphic and rarity filters, row hydration, the 廣韻 Guǎngyùn
# join with its verbatim quotations, variant grouping, and the annotation
# renderer.
#
# Runs no aggregate scans. The heaviest single step is the Mandarin slot index
# at roughly 44,000 rows.
#
# Counts are asserted as ranges, not exact figures, so re-importing a source
# does not turn a working tool into a red run. The two exceptions are marked:
# they guard specific regressions rather than describing the data.

require "benchmark"

# This file deliberately has no `require` for the application. It is meant to
# run INSIDE an already-booted Rails process, which is what `bin/rails runner`
# gives it.
#
# Started with plain `ruby`, none of the app's classes exist, so the first
# assertion dies on `uninitialized constant ToolsController` — a message that
# points at the code when the problem is the launcher. Checked here so it says
# so instead.
unless defined?(Rails) && defined?(ToolsController)
  abort <<~MESSAGE
    This needs the Rails environment. Run it through the runner:

        bin/rails runner script/character_query_smoke.rb

    Plain `ruby script/character_query_smoke.rb` starts a bare interpreter with
    none of the application loaded, so ToolsController and friends do not exist.
  MESSAGE
end

def t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
def since(s) = format("%.1fs", Process.clock_gettime(Process::CLOCK_MONOTONIC) - s)

$fails = 0
def ok(label, cond, extra = nil)
  $fails += 1 unless cond
  puts format("  %-5s %-44s %s", cond ? "ok" : "FAIL", label, extra)
end

puts "== wiring =="
ok("concern included", ToolsController.include?(CharacterQueryable))
ok("query action", ToolsController.instance_methods.include?(:character_query))
ok("slots action", ToolsController.instance_methods.include?(:character_query_slots))
ok("route helper", Rails.application.routes.url_helpers.respond_to?(:tools_character_query_path))
ok("slots route is POST",
   Rails.application.routes.routes.any? { |r| r.path.spec.to_s.include?("character_query/slots") && r.verb == "POST" })
label = I18n.t("character_query.labels.family", default: "MISSING")
ok("i18n loaded", label != "MISSING", label)
# The panel was called "Historical traits" and its tone control "Middle
# Chinese tone", neither of which named a book. Both now say 韻書, because the
# facets belong to one book and to no other.
ok("rime book panel names its subject",
   I18n.t("character_query.sections.rime_books", default: "").include?("韻書"))
ok("no unscoped Middle Chinese tone label",
   I18n.t("character_query.labels.middle_chinese_tone", default: "GONE") == "GONE")
%w[character_query_controller.js character_query_form_controller.js].each do |file|
  ok("stimulus file present: #{file}", Rails.root.join("app/javascript/controllers", file).exist?)
end

puts "== picker tree =="
tree = CharacterQuery::FamilyRegistry
ok("five families", tree.family_keys.size == 5, tree.family_keys.join(" "))
st = tree.branches_for("sino_tibetan").map { |b| b[:key] }
# "historical" held everything from 上古 to 老國音 in one dropdown, as peers.
# Split by period, and a period with nothing in it does not render: the corpus
# holds no 韻鏡 or 七音略, so late_middle_chinese is legitimately absent here.
ok("sino-tibetan branches", st.include?("yue") && st.include?("early_middle_chinese"),
   "#{st.size}: #{st.join(' ')}")
ok("the flat historical branch is gone", st.exclude?("historical"))
jp = tree.branches_for("japonic")
ok("japonic has japanese + okinawan", jp.map { |b| b[:key] }.sort == %w[japanese okinawan], jp.map { |b| b[:key] }.join(" "))
ok("single-system branch collapses", jp.first[:single_system].present?, jp.first[:single_system].to_s)
yue = tree.options_for_branch("sino_tibetan", "yue")
ok("yue: named + common + all", yue["named"].any? && yue["common"].size == 4 && yue["all"].size > 70,
   "named=#{yue['named'].size} common=#{yue['common'].size} all=#{yue['all'].size}")
hakka = tree.options_for_branch("sino_tibetan", "hakka")
ok("hakka: no common, full list", hakka["common"].empty? && hakka["all"].size > 50, "all=#{hakka['all'].size}")
hist = tree.options_for_branch("sino_tibetan", "early_middle_chinese")
# Reconstructions and attested books are separate groups, never one list: 廣韻
# records 徳紅切, and Baxter & Sagart say what they think that spelling sounded
# like. Presenting them as peers is how a reading from one ends up shown under
# the authority of the other.
ok("early middle chinese has reconstructions", hist["named"].size >= 2,
   hist["named"].map(&:first).join(" "))
ok("and its books, in their own group", hist["rime_books"].size >= 4,
   hist["rime_books"].map(&:first).join(" "))
ok("each book is labelled with its own date",
   hist["rime_books"].all? { |label, _, _| label.match?(/\d{3,4}/) })
ok("洪武正韻 is not among them", hist["rime_books"].none? { |l, _, _| l.include?("洪武") })
late = tree.options_for_branch("sino_tibetan", "early_mandarin")
ok("五音集韻 and 洪武正韻 are 近代",
   %w[五音集韻 洪武正韻].all? { |t| late["rime_books"].any? { |l, _, _| l.include?(t) } },
   late["rime_books"].map(&:first).join(" "))
# Entries are [label, value, hint]: the hint becomes the option's title so the
# romanisation shows on hover instead of spending label width.
sample = (yue["all"] + hist["named"]).first
ok("options carry a hover hint slot", sample.is_a?(Array) && sample.size == 3, sample.inspect)

puts "== queryable guard =="
%w[mandarin cantonese japanese_on korean_hangul vietnamese zhuang general_chinese
   okinawan_shuri jejueo old_chinese_bs2014 middle_chinese_bs2014 middle_chinese_bs2006
   zhongyuan menggu_ziyun laoguoyin].each do |id|
  ok("queryable: #{id}", CharacterQuery::ReadingSystem.queryable?(id))
end
ok("hidden system excluded", !CharacterQuery::ReadingSystem.queryable?("mandarin_broad"))

puts "== slot index: character_properties path =="
s = t0
idx = CharacterQuery::SlotIndex.for("mandarin")
ok("mandarin index built", idx.is_a?(Hash) && idx.size > 300, "#{idx.size} syllables in #{since(s)}")
ok("lu and lü stay distinct", idx.key?("lu") && idx.key?("lü"),
   "lu=#{idx.dig('lu', 'all')&.size} lü=#{idx.dig("lü", 'all')&.size}")
s = t0
CharacterQuery::SlotIndex.for("mandarin")
ok("second call cached", true, since(s))

puts "== slot index: table-backed path =="
s = t0
lgy = CharacterQuery::SlotIndex.for("laoguoyin")
ok("laoguoyin from its own table", lgy.is_a?(Hash) && lgy.size > 50, "#{lgy.size} syllables in #{since(s)}")

puts "== thin records (coverage notice territory) =="
oki = CharacterQuery::SlotIndex.coverage("okinawan_shuri")
jje = CharacterQuery::SlotIndex.coverage("jejueo")
ok("okinawan coverage", oki[:character_count].positive?, "#{oki[:character_count]} characters, #{oki[:slot_count]} syllables")
ok("jejueo coverage", jje[:character_count].positive?, "#{jje[:character_count]} characters, #{jje[:slot_count]} syllables")

puts "== typing a bare syllable =="
ba = CharacterQuery::SlotIndex.codepoint_ids(system_id: "mandarin", slot: "ba")
ok("ba returns characters", ba.size > 10, "#{ba.size} characters")

puts "== tone binding =="
all = CharacterQuery::SlotIndex.codepoint_ids(system_id: "mandarin", slot: "yi")
one = CharacterQuery::SlotIndex.codepoint_ids(system_id: "mandarin", slot: "yi", tone: 1)
ok("yi tone-blind", all.size > 700, all.size.to_s)
ok("yi1 narrower", one.size.positive? && one.size < all.size, "#{one.size} vs #{all.size}")

puts "== nothing to search for =="
# The controller rejects this before building a Query; the guard inside Query
# is the second line of defence, and it must not return the whole repertoire.
blank = CharacterQuery::Query.new(system: "mandarin").call
ok("empty query returns nothing", blank.rows.empty? && blank.total.zero?)
ok("and says why", blank.warnings.any? { |w| w[:code] == :no_criteria }, blank.warnings.inspect)

puts "== full query with meaning columns =="
s = t0
res = CharacterQuery::Query.new(system: "mandarin", slot: "yi",
                                columns: %w[kMandarin kDefinition], per_page: 3).call
ok("rows hydrated", res.rows.size == 3, "#{res.primary_count} in slot, #{since(s)}")
ok("char and codepoint", res.rows.all? { |r| r[:char].present? && r[:codepoint].to_i.positive? },
   res.rows.map { |r| r[:char] }.join(" "))
ok("properties attached", res.rows.any? { |r| r[:properties]["kMandarin"].present? })
ok("steps structured", res.steps.first[:detail].is_a?(Hash))

puts "== rare readings: one control, not two =="
# Rare readings are searched by default; "everyday characters only" turns them
# off rather than running alongside them. Two checkboxes cancelled each other:
# kHanyuPinyin's extra readings belong overwhelmingly to characters outside
# Unihan's core set, so gathering them and then filtering the characters away
# did the work twice to arrive back where it started.
wide = CharacterQuery::Query.new(system: "mandarin", slot: "yi", per_page: 1).call
core = CharacterQuery::Query.new(system: "mandarin", slot: "yi", common_only: true, per_page: 1).call
ok("rare readings are in by default", wide.primary_count > core.primary_count,
   "#{wide.primary_count} -> #{core.primary_count} with everyday characters only")
ok("the default search reports itself as broad",
   wide.steps.first.dig(:detail, :broadened) == true)
ok("everyday characters only reports itself as narrow",
   core.steps.first.dig(:detail, :broadened) == false)

puts "== second-system constraint =="
s = t0
res2 = CharacterQuery::Query.new(system: "mandarin", slot: "yi",
                                 constraints: [{ system: "cantonese", slot: "ji" }],
                                 columns: %w[kMandarin], per_page: 5).call
ok("yi and cantonese ji", res2.total.between?(100, 300),
   "#{res2.primary_count} -> #{res2.total} in #{since(s)}")

puts "== homophone seeker =="
s = t0
hp = CharacterQuery::Query.new(system: "mandarin", homophone_of: "一",
                               columns: %w[kMandarin], per_page: 5).call
ok("一 has homophones", hp.total > 100, "#{hp.total} characters in #{since(s)}")
toned = CharacterQuery::Query.new(system: "mandarin", homophone_of: "一",
                                  match_tone: true, per_page: 5).call
ok("matching tone narrows it", toned.total.positive? && toned.total < hp.total,
   "#{hp.total} -> #{toned.total}")
# The same character read through a different system should give a different
# set, since jat1 and yī do not carry the same company.
yue_hp = CharacterQuery::Query.new(system: "cantonese", homophone_of: "一", per_page: 5).call
ok("cantonese gives its own set", yue_hp.total.positive? && yue_hp.total != hp.total,
   "cantonese #{yue_hp.total} vs mandarin #{hp.total}")
missing = CharacterQuery::Query.new(system: "mandarin", homophone_of: "\u{10FFFD}", per_page: 5).call
ok("unknown character says so", missing.warnings.any? { |w| w[:code] == :character_not_found },
   missing.warnings.inspect)
# 一 was the wrong example here: Jejueo records 일 for it, so the warning
# correctly did not fire and the assertion was testing my assumption rather
# than the code. 水 has a Mandarin reading and no Jejueo one.
present = CharacterQuery::Query.new(system: "jejueo", homophone_of: "一", per_page: 5).call
ok("a character Jejueo does record is found", present.total.positive?,
   "#{present.total} sharing 一's Jejueo reading")
silent = CharacterQuery::Query.new(system: "jejueo", homophone_of: "水", per_page: 5).call
ok("character with no reading there says so",
   silent.total.zero? && silent.warnings.any? { |w| w[:code] == :no_readings_for_character },
   silent.warnings.inspect)

puts "== component search =="
s = t0
comp = CharacterQuery::Query.new(system: "mandarin", component: "木",
                                 columns: %w[kMandarin], per_page: 5).call
ok("木 as a component", comp.total.between?(2_000, 8_000), "#{comp.total} characters in #{since(s)}")
ok("rows hydrated", comp.rows.size == 5 && comp.rows.all? { |r| r[:char].present? },
   comp.rows.map { |r| r[:char] }.join(" "))

puts "== IDS search =="
s = t0
ids = CharacterQuery::Query.new(system: "mandarin", ids_expression: "⿰木",
                                columns: %w[kMandarin], per_page: 5).call
ok("⿰木 prefix", ids.total.between?(1_500, 5_000), "#{ids.total} characters in #{since(s)}")

# Regression guard, not a description of the data. The prefix search is a
# range rather than a LIKE, because LIKE cannot use the index and scans all
# 355,698 rows (0.753s against 0.005s). The range's ceiling must be U+10FFFF:
# UTF-8 under BINARY collation sorts in code point order, so a U+FFFF ceiling
# silently drops every expression whose next character is astral — ⿰木𫈼,
# ⿰木𠘻 and 203 others for ⿰木 alone, which is exactly the rare repertoire
# someone searching by structure came for. Both bounds are counted here so the
# check describes the bug rather than today's row count.
bmp_ceiling = CharacterStructure.where(system: "ids")
                                .where("normalized_expression >= ? AND normalized_expression < ?", "⿰木", "⿰木￿")
                                .distinct.count(:character_codepoint_id)
ok("astral components survive the prefix range", ids.total > bmp_ceiling,
   "#{ids.total} found; a U+FFFF ceiling would return #{bmp_ceiling}")
ok("IDS search is indexed (under a second)",
   Benchmark.realtime { CharacterQuery::Query.new(system: "mandarin", ids_expression: "⿰氵", per_page: 1).call } < 1.0)

# The shared builder writes "?" into slots the reader left open, so the three
# shapes below all arrive from the same control. Each takes a different SQL
# form; all three must stay indexed.
exact = CharacterQuery::Query.new(system: "mandarin", ids_expression: "⿰木目", per_page: 5).call
ok("a complete expression matches exactly", exact.total.positive? && exact.total < 20, exact.total.to_s)
trailing = CharacterQuery::Query.new(system: "mandarin", ids_expression: "⿰木?", per_page: 5).call
ok("⿰木? is the same as the bare prefix", trailing.total == ids.total, "#{trailing.total} vs #{ids.total}")
inner = CharacterQuery::Query.new(system: "mandarin", ids_expression: "⿰?木", per_page: 2_000).call
ok("⿰?木 finds 木 on the right", inner.total.positive? && inner.total < trailing.total,
   "#{inner.total} with 木 on the right, #{trailing.total} with it on the left")
ok("an open slot matches a whole subtree, not one character",
   inner.rows.any? { |row| Array(row[:properties]).any? } || inner.total.positive?)
ok("a bare ? constrains nothing",
   CharacterQuery::Query.new(system: "mandarin", slot: "yi", ids_expression: "?", per_page: 1).call.total ==
   CharacterQuery::Query.new(system: "mandarin", slot: "yi", per_page: 1).call.total)
ok("inner-slot search stays under a second",
   Benchmark.realtime { CharacterQuery::Query.new(system: "mandarin", ids_expression: "⿰?氵", per_page: 1).call } < 1.0)

puts "== reading and structure together =="
s = t0
both = CharacterQuery::Query.new(system: "mandarin", slot: "yi", component: "木",
                                 columns: %w[kMandarin], per_page: 5).call
ok("yi narrowed by 木", both.total.positive? && both.total < comp.total,
   "#{both.total} characters in #{since(s)}")
ok("component recorded as a step", both.steps.any? { |st| st[:kind] == :component }, both.steps.map { |x| x[:kind] }.inspect)

puts "== graphic and rarity filters =="
s = t0
rad = CharacterQuery::Query.new(system: "mandarin", slot: "yi", radical: "9", per_page: 5).call
ok("radical 9 (人)", rad.total.positive? && rad.total < res.primary_count, "#{rad.total} of #{res.primary_count}")
strokes = CharacterQuery::Query.new(system: "mandarin", slot: "yi", total_strokes: 9, per_page: 5).call
ok("nine strokes", strokes.total.positive? && strokes.total < res.primary_count, "#{strokes.total} of #{res.primary_count}")
common = CharacterQuery::Query.new(system: "mandarin", slot: "yi", common_only: true, per_page: 5).call
ok("common only", common.total.positive? && common.total < res.primary_count,
   "#{common.total} of #{res.primary_count} in #{since(s)}")
ok("radical grid covers all 214",
   (0...214).map { |i| [0x2F00 + i].pack("U") }.uniq.size == 214)

puts "== paging, not truncation =="
# There is no maximum result count any more. The total is the true figure, a
# page is a slice of it, and CSV export takes the whole set regardless.
s = t0
p1 = CharacterQuery::Query.new(system: "mandarin", slot: "yi", per_page: 50, page: 1).call
p2 = CharacterQuery::Query.new(system: "mandarin", slot: "yi", per_page: 50, page: 2).call
whole = CharacterQuery::Query.new(system: "mandarin", slot: "yi", per_page: CharacterQuery::Query::ALL).call
ok("page one holds a page", p1.rows.size == 50, "#{p1.rows.size} of #{p1.total}")
ok("page two holds different characters",
   (p1.rows.map { |r| r[:codepoint] } & p2.rows.map { |r| r[:codepoint] }).empty?)
ok("the total is the same on every page", p1.total == p2.total && p1.total == whole.total, p1.total.to_s)
ok("page count is consistent", p1.page_count == (p1.total / 50.0).ceil, p1.page_count.to_s)
ok("all really means all", whole.rows.size == whole.total && whole.page_count == 1,
   "#{whole.rows.size} rows in #{since(s)}")
ok("a page past the end is empty, not an error",
   CharacterQuery::Query.new(system: "mandarin", slot: "yi", per_page: 50, page: 9_999).call.rows.empty?)
ok("no MAX_ROWS constant survives", !CharacterQuery::Query.constants.include?(:MAX_ROWS))

puts "== the 214 radicals, derived from the corpus =="
radicals = CharacterQuery::KangxiRadicals.all
ok("all 214 present", radicals.size == 214)
ok("every one has a unified glyph, not a block symbol",
   radicals.all? { |r| r[:glyph].present? && r[:glyph] != r[:symbol] },
   radicals.first(6).map { |r| r[:glyph] }.join)
ok("stroke counts resolve for all of them",
   radicals.count { |r| r[:strokes].to_i.positive? } == 214,
   radicals.reject { |r| r[:strokes].to_i.positive? }.map { |r| r[:number] }.inspect)
ok("radical 1 is 一, one stroke", radicals.first[:glyph] == "一" && radicals.first[:strokes] == 1)
ok("radical 214 is 龠", radicals.last[:glyph] == "龠", radicals.last[:strokes].to_s)
ok("groups run fewest strokes first",
   CharacterQuery::KangxiRadicals.groups.map(&:first).compact.each_cons(2).all? { |a, b| a < b },
   CharacterQuery::KangxiRadicals.groups.map { |strokes, rs| "#{strokes}:#{rs.size}" }.join(" "))

puts "== Middle Chinese tone is a letter, not an absence =="
# Baxter writes 上聲 as a final X and 去聲 as a final H; 入聲 is marked by the
# stop coda, which is part of the syllable and stays. Treating these as
# toneless made dang, dangX and dangH three unrelated slots.
{ "dang" => ["dang", 1], "dangX" => ["dang", 2], "dangH" => ["dang", 3], "dak" => ["dak", 4] }
  .each do |reading, want|
  ok("MC split #{reading}", CharacterQuery::ReadingSystem.split(reading, "middle_chinese_bs2014") == want,
     CharacterQuery::ReadingSystem.split(reading, "middle_chinese_bs2014").inspect)
end
# Old Chinese had no tones. The *-ʔ and *-s that 上聲 and 去聲 descend from
# are derivational suffixes — *lˤaŋ and *lˤaŋ-s are two words, like deal and
# dealer — so the reconstruction is stored as it stands, minus the asterisk.
# Merging them claimed a homophony the source does not: 525 stem/derivative
# pairs are both attested here.
{ "*laŋ" => ["laŋ", nil], "*laŋʔ" => ["laŋʔ", nil],
  "*lˤaŋ-s" => ["lˤaŋ-s", nil], "*lak" => ["lak", nil],
  "*(mə-)toŋʔ-s" => ["(mə-)toŋʔ-s", nil] }.each do |reading, want|
  ok("OC verbatim #{reading}", CharacterQuery::ReadingSystem.split(reading, "old_chinese_bs2014") == want,
     CharacterQuery::ReadingSystem.split(reading, "old_chinese_bs2014").inspect)
end
# Case is notation: C an unknown consonant, N a nasal prefix, A a vowel.
ok("OC keeps its capitals",
   CharacterQuery::ReadingSystem.split("*lAjʔ", "old_chinese_bs2014") != 
   CharacterQuery::ReadingSystem.split("*lajʔ", "old_chinese_bs2014"),
   CharacterQuery::ReadingSystem.split("*lAjʔ", "old_chinese_bs2014").inspect)
ok("a typed spec finds it with or without the asterisk",
   CharacterQuery::ReadingSystem.parse_spec("*lˤaŋ-s", "old_chinese_bs2014") ==
   CharacterQuery::ReadingSystem.parse_spec("lˤaŋ-s", "old_chinese_bs2014"))
ok("a typed dang means any tone",
   CharacterQuery::ReadingSystem.parse_spec("dang", "middle_chinese_bs2014") == ["dang", nil])
ok("a typed dangX binds 上聲",
   CharacterQuery::ReadingSystem.parse_spec("dangX", "middle_chinese_bs2014") == ["dang", 2])
ok("a lowercase x is not a tone",
   CharacterQuery::ReadingSystem.split("max", "middle_chinese_bs2014") == ["max", 1])
# The cache is invalidated by row count, which a normalisation change cannot
# move. If this is still 2 after changing how readings split, every system is
# serving a stale index.
ok("slot cache version was bumped for the tone change",
   CharacterQuery::SlotIndex::FORMAT_VERSION >= 5, CharacterQuery::SlotIndex::FORMAT_VERSION.to_s)
mc = CharacterQuery::SlotIndex.for("middle_chinese_bs2014")
ok("X and H folded into their base slot", mc.key?("dang") && !mc.key?("dangX"),
   "#{mc.size} slots")

puts "== a syllable that is not in the system at all =="
# Xiaoxuetang writes Shanghai's voiced onset zɦ where most of Wu writes z, so
# zɿ matches nothing in Shanghai while zɦɿ holds 89 characters including 是.
# "Nothing found" is a useless answer to that; the near slots are the answer.
shanghai = CharacterQuery::FamilyRegistry.topolect_system_ids.find { |id| id.to_s.end_with?("126") }
if shanghai
  near = CharacterQuery::SlotIndex.nearest_slots(shanghai, "zɿ")
  ok("zɿ suggests zɦɿ", near.first && near.first[:slot] == "zɦɿ",
     near.map { |h| "#{h[:slot]} (#{h[:count]})" }.join(", "))
  miss = CharacterQuery::Query.new(system: shanghai, slot: "zɿ", per_page: 5).call
  ok("and the query says so rather than going quiet",
     miss.warnings.any? { |w| w[:code] == :slot_not_in_system && w[:suggestions].present? },
     miss.warnings.inspect[0, 120])
  ok("nonsense suggests nothing", CharacterQuery::SlotIndex.nearest_slots(shanghai, "qqqq").empty?)
else
  puts "  SKIP  Shanghai locality not discovered"
end

puts "== why each character is in the set =="
# 湯 answers a search for yáng because 漢語大字典 records 湯谷; without the
# reading on the row that looks like a bug, and it is not.
yang = CharacterQuery::Query.new(system: "mandarin", slot: "yang", columns: %w[kMandarin], per_page: 2_000).call
tang = yang.rows.find { |row| row[:char] == "湯" }
ok("湯 is in yang", tang.present?, "#{yang.total} characters read yang")
ok("and says which reading put it there", tang.nil? || tang[:matched].present?,
   tang&.dig(:matched)&.map { |h| "#{h[:reading]} (#{h[:field]})" }&.join(", ").to_s)
ok("every row carries its matched reading",
   yang.rows.all? { |row| row[:matched].present? },
   "#{yang.rows.count { |row| row[:matched].blank? }} rows without one")

puts "== comparing a character across two systems =="
# The syllable may be left blank in a second system when a character is given:
# it is read off that character there. Typing IPA from memory is exactly where
# a comparison falls over.
if shanghai
  beijing = CharacterQuery::FamilyRegistry.topolect_system_ids.find { |id| id.to_s.end_with?("027") }
  if beijing
    compared = CharacterQuery::Query.new(system: beijing, homophone_of: "是",
                                         constraints: [{ system: shanghai, slot: nil, tone: nil }],
                                         per_page: 50).call
    ok("是 in Beijing ∩ its own Shanghai reading", compared.total.positive?,
       "#{compared.primary_count} -> #{compared.total}: #{compared.rows.map { |r| r[:char] }.join}")
    ok("是 is in its own result", compared.rows.any? { |r| r[:char] == "是" })
    ok("the step says the syllable came from the character",
       compared.steps.any? { |st| st[:kind] == :secondary && st.dig(:detail, :from_character).present? })
  end
end

puts "== dictionary join and quotations =="
s = t0
gy = DictionaryWork.find_by(title: "廣韻")
ok("found 廣韻", gy.present?, gy&.id&.to_s)
res3 = CharacterQuery::Query.new(system: "mandarin", slot: "yi",
                                 dictionary_filters: { work_id: gy&.id, tone: "入聲" },
                                 dictionary_columns: [gy&.id].compact,
                                 columns: %w[kMandarin], per_page: 3).call
ok("entering-tone filter", res3.total.positive?, "#{res3.total} characters in #{since(s)}")
ok("quotations attached", res3.rows.any? { |r| r[:dictionary_entries].present? },
   res3.rows.first&.dig(:dictionary_entries)&.first&.values_at(:work_title, :tone)&.join(" ").to_s)

puts "== rime books are sources, not a shared vocabulary =="
# The defect this guards: the tone and 韻目 filters had no book behind them.
# apply_dictionary_filters only added `dw_work.id = ?` when work_id was given,
# and the form never sent one, so 上聲 matched 廣韻, 集韻, 五音集韻, 切韻 AND
# 洪武正韻 at once — a Ming standard included, under a label reading "Middle
# Chinese tone".
books = CharacterQuery::RimeBooks.books
ok("books registered", books.size >= 6, books.map { |b| b[:label] }.join(" "))
ok("every book carries a date", books.all? { |b| b[:year].to_i.positive? })
emc = CharacterQuery::RimeBooks.for_period("early_middle_chinese").map { |b| b[:title] }
ok("廣韻 records the 切韻 system", emc.include?("廣韻"), emc.uniq.join(" "))
jd = CharacterQuery::RimeBooks.for_period("early_mandarin").map { |b| b[:title] }
ok("五音集韻 and 洪武正韻 are 近代", jd.sort == %w[五音集韻 洪武正韻], jd.join(" "))

# 玉篇 is a 字書 arranged by 部首. Its rhyme_label values are 一部, 示部, 玉部,
# so offering them as 韻目 would match radicals as rime categories, and its
# small_rime_number is an entry index rather than a 小韻.
yupian = books.find { |b| b[:title] == "玉篇" }
ok("玉篇 is filed by 部首, not 韻目", yupian[:section_axis] == :radical)
ok("玉篇 offers no tone and no 小韻",
   (yupian[:facets] & %i[tone small_rime]).empty?, yupian[:facets].inspect)

# Each book's vocabulary is its own. 上平聲/下平聲 are 廣韻's fascicle
# headings, not tones, and no other book writes them; plain 平聲 is what the
# others use and was not offered at all.
gy_id = books.find { |b| b[:title] == "廣韻" }[:id]
jy_id = books.find { |b| b[:title] == "集韻" }[:id]
gy_tones = CharacterQuery::RimeBooks.vocabulary(gy_id)[:tones]
jy_tones = CharacterQuery::RimeBooks.vocabulary(jy_id)[:tones]
ok("廣韻 offers its fascicle headings", gy_tones.include?("上平聲"), gy_tones.join(" "))
ok("集韻 offers plain 平聲 and not 上平聲",
   jy_tones.include?("平聲") && jy_tones.exclude?("上平聲"), jy_tones.join(" "))
ok("tones come in the book's own order, not alphabetical",
   gy_tones.last == "入聲" && jy_tones.first == "平聲")

# Refusal, not a silent union.
loose = CharacterQuery::Query.new(system: "mandarin", slot: "yi",
                                  dictionary_filters: { tone: "上聲" }, per_page: 5).call
ok("a facet with no book returns nothing", loose.total.zero?)
ok("and says which decision is missing",
   loose.warnings.any? { |w| w[:code] == :rime_book_not_chosen }, loose.warnings.inspect)

# Scoped, the count is one book's and no one else's.
scoped = CharacterQuery::Query.new(system: gy_id,
                                    dictionary_filters: { tone: "上聲" }, per_page: 5).call
direct = DictionaryEntryCharacter
         .joins("INNER JOIN dictionary_entries de ON de.id = dictionary_entry_characters.dictionary_entry_id")
         .joins("INNER JOIN dictionary_sections ds ON ds.id = de.dictionary_section_id")
         .where("de.dictionary_work_id = ? AND ds.tone = ?",
                CharacterQuery::RimeBooks.find(gy_id)[:work_id], "上聲")
         .distinct.count("dictionary_entry_characters.character_codepoint_id")
ok("廣韻 上聲 is exactly 廣韻's", scoped.total == direct, "#{scoped.total} vs #{direct} counted directly")

# A book as the source needs no syllable: its facets are the question.
whole = CharacterQuery::Query.new(system: gy_id, per_page: 5).call
ok("a book on its own returns what it covers", whole.total > scoped.total,
   "#{whole.total} characters in 廣韻")
ok("no 'nothing to search for' complaint",
   whole.warnings.none? { |w| w[:code] == :no_criteria }, whole.warnings.inspect)

# The same, reached through the panel instead of the picker.
via_panel = CharacterQuery::Query.new(
  system: "mandarin",
  dictionary_filters: { work_id: CharacterQuery::RimeBooks.find(gy_id)[:work_id], tone: "上聲" },
  per_page: 5
).call
ok("a book plus a facet is a complete query", via_panel.total == scoped.total,
   "#{via_panel.total} vs #{scoped.total}")

# The book's matched column shows the book's own datum.
east = CharacterQuery::Query.new(system: gy_id,
                                  dictionary_filters: { rhyme_label: "東" }, per_page: 40).call
labels = east.rows.flat_map { |r| Array(r[:matched]).flat_map { |m| Array(m[:readings]).map { |x| x[:reading] } } }
ok("matched column carries 反切, not a romanisation",
   labels.any? { |l| l.include?("切") }, labels.first.to_s)
ok("an inherited 小韻 spelling is marked", labels.any? { |l| l.start_with?("(") },
   labels.find { |l| l.start_with?("(") }.to_s)

# Naming two books is a conflict, not a preference.
clash = CharacterQuery::Query.new(
  system: gy_id,
  dictionary_filters: { work_id: CharacterQuery::RimeBooks.find(jy_id)[:work_id], tone: "上聲" },
  per_page: 5
).call
ok("two books named is a conflict", clash.warnings.any? { |w| w[:code] == :rime_book_conflict },
   clash.warnings.inspect)

puts "== and / or =="
# Baxter & Sagart reconstruct about 4,000 characters; 廣韻 files over 16,000.
# Under AND the book can only subtract from what Baxter happens to have.
gy_work = CharacterQuery::RimeBooks.find(gy_id)[:work_id]
filters = { work_id: gy_work, tone: "上聲" }
conj = CharacterQuery::Query.new(system: "middle_chinese_bs2014", slot: "dang",
                                 dictionary_filters: filters, combine: "and", per_page: 5).call
disj = CharacterQuery::Query.new(system: "middle_chinese_bs2014", slot: "dang",
                                 dictionary_filters: filters, combine: "or", per_page: 5).call
ok("or is wider than and", disj.total > conj.total, "and=#{conj.total} or=#{disj.total}")
ok("or contains and", disj.total >= conj.total)
ok("and is the default",
   CharacterQuery::Query.new(system: "middle_chinese_bs2014", slot: "dang",
                             dictionary_filters: filters, per_page: 5).call.total == conj.total)
ok("or records itself as a step", disj.steps.any? { |st| st[:kind] == :dictionary_or },
   disj.steps.map { |st| st[:kind] }.join(" "))
# A radical still narrows the union: it is a fact about the written form and
# belongs to neither side.
narrowed = CharacterQuery::Query.new(system: "middle_chinese_bs2014", slot: "dang",
                                     dictionary_filters: filters, combine: "or",
                                     radical: 85, per_page: 5).call
ok("graphic filters still bite after a union", narrowed.total < disj.total,
   "#{narrowed.total} of #{disj.total} under radical 85")

puts "== an incomplete IDS is a prefix, not an exact match =="
# ⿰ is binary and ⿰木 supplies one operand. No stored normalized_expression is
# ever incomplete, so matching ⿰木 exactly could only ever return nothing — a
# query silently guaranteed to fail.
ok("⿰木 is incomplete", !Ids::Parser.complete?("⿰木"))
ok("⿰木目 is complete", Ids::Parser.complete?("⿰木目"))
ok("⿲彳丨亍 is complete", Ids::Parser.complete?("⿲彳丨亍"))
ok("⿲彳丨 is incomplete", !Ids::Parser.complete?("⿲彳丨"))
ok("⿱⿰木木木 is complete", Ids::Parser.complete?("⿱⿰木木木"))
ok("too many operands is not complete", !Ids::Parser.complete?("⿰木目目"))

puts "== ASCII ü input (v substitution) =="
ok("lv parses as lü", CharacterQuery::ReadingSystem.parse_spec("lv", "mandarin") == ["lü", nil])
ok("nv3 parses as nü tone 3", CharacterQuery::ReadingSystem.parse_spec("nv3", "mandarin") == ["nü", 3])
lv = CharacterQuery::SlotIndex.codepoint_ids(system_id: "mandarin", slot: "lü")
lu = CharacterQuery::SlotIndex.codepoint_ids(system_id: "mandarin", slot: "lu")
ok("lü returns its own set", lv.size.positive? && lv.size != lu.size, "lü=#{lv.size} lu=#{lu.size}")
# jv -> jü, which is not a real slot; standard pinyin writes ju. The fallback
# should find ju rather than returning nothing.
jv_slot, = CharacterQuery::ReadingSystem.parse_spec("jv", "mandarin")
jv = CharacterQuery::SlotIndex.codepoint_ids(system_id: "mandarin", slot: jv_slot)
ok("jv falls back to ju", jv.size.positive?, "#{jv_slot} -> #{jv.size} characters")
# v is a letter in Vietnamese and must not be rewritten there.
ok("v left alone outside pinyin",
   CharacterQuery::ReadingSystem.parse_spec("văn", "vietnamese").first.start_with?("v"))

puts "== scheme conversion via Phoneticization::Converters =="
if defined?(Phoneticization::Converters)
  bopo = CharacterQuery::ReadingSystem.parse_spec("ㄧ", "mandarin", scheme: :bopomofo)
  ok("bopomofo ㄧ converts", bopo.first.present?, bopo.inspect)
  wade = CharacterQuery::ReadingSystem.parse_spec("i", "mandarin", scheme: :wade_giles)
  ok("wade-giles converts", wade.first.present?, wade.inspect)
  ok("mandarin schemes offered", CharacterQuery::ReadingSystem.input_schemes("mandarin").size > 5,
     CharacterQuery::ReadingSystem.input_schemes("mandarin").keys.first(4).join(" "))
  ok("cantonese schemes offered", CharacterQuery::ReadingSystem.input_schemes("cantonese").size > 5)
  ok("toneless systems offer none", CharacterQuery::ReadingSystem.input_schemes("japanese_on").empty?)
else
  puts "  SKIP  Phoneticization::Converters not loaded"
end

puts "== variant grouping via OpenCC =="
trad = CharacterStandards.traditional("汉")
ok("opencc reachable", trad.present?, "汉 -> #{trad}")
s = t0
plain   = CharacterQuery::Query.new(system: "mandarin", slot: "yi", columns: %w[kMandarin], per_page: CharacterQuery::Query::ALL).call
grouped = CharacterQuery::Query.new(system: "mandarin", slot: "yi", columns: %w[kMandarin],
                                    group_variants: true, per_page: CharacterQuery::Query::ALL).call
ok("grouping reduces the count", grouped.total <= plain.total,
   "#{plain.total} rows -> #{grouped.total} groups in #{since(s)}")
ok("some group has members", grouped.rows.any? { |r| r[:variants].present? },
   "largest group: #{grouped.rows.map { |r| r[:variants].size }.max.to_i + 1}")
ok("members keep their own data",
   grouped.rows.flat_map { |r| r[:variants] }.all? { |v| v[:char].present? && v[:codepoint].to_i.positive? })
ok("no grouping warning", grouped.warnings.none? { |w| w[:code] == :variant_grouping_unavailable },
   grouped.warnings.inspect)
# 一 and 壹 are different words, not two spellings of one. VariantMapping folds
# them together; OpenCC does not, which is why the key is OpenCC's.
yi_row = grouped.rows.find { |r| r[:char] == "一" }
ok("一 and 壹 stay apart",
   yi_row.nil? || yi_row[:variants].none? { |v| v[:char] == "壹" },
   yi_row&.dig(:variants)&.map { |v| v[:char] }&.join(" ").to_s)

puts "== every stored reading splits, in every system =="
# The normaliser is the part with no safety net: a reading it cannot split is
# a character that silently never appears in any result, and a tone it returns
# as a Symbol raises inside Query, which calls #to_i on it. Both have happened.
# So this runs the real values rather than a fixture — one indexed query per
# system, the largest being kHanyuPinyin at ~34,000 distinct values.
s = t0
CharacterQuery::ReadingSystem::DEFINITIONS.each do |system_id, definition|
  values =
    if definition[:table].present?
      CharacterQuery::SlotIndex::TABLE_MODELS.fetch(definition[:table]).constantize
                    .distinct.pluck(definition[:column])
    else
      CharacterProperty.where(source: definition[:source], field: definition[:field])
                       .distinct.pluck(:value)
    end

  slots = Hash.new(0)
  unsplittable = []
  odd_tones = []

  values.each do |value|
    CharacterQuery::ReadingSystem.readings_in(value, system_id).each do |reading|
      slot, tone = CharacterQuery::ReadingSystem.split(reading, system_id)
      if slot.blank?
        unsplittable << reading if unsplittable.size < 3
        next
      end
      odd_tones << [reading, tone.class.name] if tone && !tone.is_a?(Integer) && odd_tones.size < 3
      slots[slot] += 1
    end
  end

  median = slots.values.sort[slots.size / 2].to_i
  ok("#{system_id}: #{slots.size} slots",
     slots.any? && unsplittable.empty? && odd_tones.empty?,
     format("median %d per slot%s%s", median,
            unsplittable.empty? ? "" : "  UNSPLITTABLE #{unsplittable.inspect}",
            odd_tones.empty? ? "" : "  NON-INTEGER TONE #{odd_tones.inspect}"))
end
puts "  (#{since(s)})"

puts "== variant grouping, from two sources =="
# OpenCC normalises script; the Taiwan MOE 異體字字典 records orthographic
# variance proper. They answer different questions, so they are independently
# selectable, and "both" is the transitive closure — which is why the
# implementation is union-find and not grouping on a key.
s = t0
plain = CharacterQuery::Query.new(system: "mandarin", slot: "dang", per_page: 1).call
modes = {}
%w[opencc moe both].each do |mode|
  modes[mode] = CharacterQuery::Query.new(system: "mandarin", slot: "dang",
                                          group_variants: mode, per_page: 1).call
end
ok("every mode groups something", modes.values.all? { |r| r.total < plain.total },
   "ungrouped #{plain.total}; " + modes.map { |m, r| "#{m} #{r.total}" }.join(", ") + " in #{since(s)}")
ok("both is at least as coarse as either alone",
   modes["both"].total <= [modes["opencc"].total, modes["moe"].total].min)
ok("the old checkbox value still means OpenCC",
   CharacterQuery::Query.new(system: "mandarin", slot: "dang", group_variants: "1", per_page: 1).call.total ==
   modes["opencc"].total)
ok("an unknown mode groups nothing rather than guessing",
   CharacterQuery::Query.new(system: "mandarin", slot: "dang", group_variants: "wat", per_page: 1).call.total ==
   plain.total)
ok("the step records which source was used",
   modes["moe"].steps.any? { |st| st[:kind] == :group_variants && st.dig(:detail, :method) == "moe" })

# Nothing may be lost to grouping: every character still appears exactly once,
# as a head or as a member.
whole = CharacterQuery::Query.new(system: "mandarin", slot: "dang",
                                  group_variants: "both", per_page: CharacterQuery::Query::ALL).call
members = whole.rows.flat_map { |row| [row[:char]] + Array(row[:variants]).map { |v| v[:char] } }
ok("no character is lost or duplicated by grouping",
   members.size == plain.total && members.uniq.size == members.size,
   "#{members.size} characters across #{whole.total} groups, was #{plain.total}")
ok("MOE joins 蕩 蘯 簜",
   whole.rows.any? { |row| ([row[:char]] + Array(row[:variants]).map { |v| v[:char] }).then { |g|
     g.include?("蕩") && g.include?("蘯") } })

puts "== annotation renderer =="
text = CharacterQuery::AnnotationRenderer.new(res3.rows).to_text
ok("renders a block", text.present?, text.lines.first&.strip)
ok("gloss markers behave", true, text.include?("[gloss]") ? "[gloss] markers present" : "all glossed")

puts
puts $fails.zero? ? "ALL SMOKE CHECKS PASSED" : "#{$fails} CHECK(S) FAILED"
exit($fails.zero? ? 0 : 1)
