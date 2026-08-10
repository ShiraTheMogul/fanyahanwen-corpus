# frozen_string_literal: true

module CharacterData
  module SourceCatalogue
    SOURCES = {
      "cangjie5" => {
        label: "RIME Cangjie 5",
        source: "rime/rime-cangjie",
        version: "52d90a1b1312e74042b38c1cbc8142defbc53171",
        url: "https://raw.githubusercontent.com/rime/rime-cangjie/52d90a1b1312e74042b38c1cbc8142defbc53171/cangjie5.dict.yaml",
        format: "rime_dict",
        kind: "input",
        license: "GPL (dictionary header)"
      },
      "wubi86" => {
        label: "RIME Wubi 86",
        source: "rime/rime-wubi",
        version: "152a0d3f3efe40cae216d1e3b338242446848d07",
        url: "https://raw.githubusercontent.com/rime/rime-wubi/152a0d3f3efe40cae216d1e3b338242446848d07/wubi86.dict.yaml",
        format: "rime_dict",
        kind: "input",
        license: "LGPL-3.0"
      },
      "moran" => {
        label: "RIME Moran auxiliary code",
        source: "rimeinn/rime-moran",
        version: "6e2cb0c669e91cf1fedd7d403b5413c3551fe1ac",
        url: "https://raw.githubusercontent.com/rimeinn/rime-moran/6e2cb0c669e91cf1fedd7d403b5413c3551fe1ac/tools/data/moran_chai.txt",
        format: "moran_aux",
        kind: "auxiliary",
        license: "GPL-3.0"
      }
    }.freeze

    module_function

    def fetch(system_id)
      SOURCES.fetch(system_id.to_s)
    end
  end
end
