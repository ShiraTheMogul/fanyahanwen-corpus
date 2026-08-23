# frozen_string_literal: true

# Adds two bounded behaviours to the existing Corpus Viewer controller:
#
# 1. large multi-document works are presented as paged directory-style lists;
# 2. the root Corpus Viewer can swap its normal folder browser for work-title
#    results without introducing a second public catalogue page.
#
# The title index is still a separate maintenance cache internally.  That keeps
# title discovery cheap while the user-facing concept stays one Corpus Viewer.
module CorpusViewerWorkPagination
  def show
    return render_work_title_results if work_title_search_requested?

    super
  end

  private

  def work_title_search_requested?
    params[:path].to_s.blank? && params[:catalogue_q].to_s.strip.present?
  end

  def render_work_title_results
    request.format = :html
    @rel_path = ""
    @kind = :dir
    @corpus_grid_view = false
    @catalogue_search_active = true
    @catalogue_query = params[:catalogue_q].to_s.strip
    @catalogue_order = params[:catalogue_order].to_s == "desc" ? "desc" : "asc"
    @catalogue_geography = params[:catalogue_geography].to_s == "1"

    @catalogue_page = CorpusCatalogueIndex.load.timeline(
      query: @catalogue_query,
      order: @catalogue_order,
      geography: @catalogue_geography,
      page: params[:page],
      per_page: 100
    )

    render "corpus_viewer/catalogue_results", formats: [:html]
  rescue CorpusCatalogueIndex::CacheMissing => e
    @catalogue_error = e.message
    @catalogue_page = CorpusCatalogueIndex::Page.new(
      items: [], page: 1, per_page: 100, total: 0, total_pages: 1
    )
    render "corpus_viewer/catalogue_results", formats: [:html]
  end

  def load_work_folder_index(fs:, metadata_store:, work_listing:)
    super

    visible_names = Array(@work_document_paths).map do |path|
      relative = path.to_s.tr("\\", "/")
      prefix = @rel_path.to_s.sub(%r{/+\z}, "")
      relative.start_with?("#{prefix}/") ? relative.delete_prefix("#{prefix}/") : relative
    end

    @kind = :dir
    @children = visible_names
    @directory_page = CorpusFs::DirectoryPage.new(
      items: visible_names,
      page: @work_page.page,
      per_page: @work_page.per_page,
      raw_total: @work_page.total,
      total_pages: @work_page.total_pages
    )
  end
end
