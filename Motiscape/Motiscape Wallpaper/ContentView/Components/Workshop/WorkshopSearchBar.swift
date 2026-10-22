import SwiftUI

struct WorkshopSearchBar: View {
    @Bindable var workshopViewModel: WorkshopViewModel
    @Bindable var viewModel: ContentViewModel

    var body: some View {
        HStack(spacing: BrowseToolbarMetrics.spacing) {
            BrowseSearchField(
                prompt: L("搜索作品、作者或作品 ID..."),
                text: $workshopViewModel.searchText,
                onSubmit: { workshopViewModel.submitSearch() },
                onClear: {
                    workshopViewModel.searchText = ""
                    workshopViewModel.currentPage = 1
                    workshopViewModel.search()
                }
            )
            .accessibilityIdentifier("workshop.search")

            HStack(spacing: BrowseToolbarMetrics.spacing) {
                Button {
                    workshopViewModel.refreshSearch()
                } label: {
                    Group {
                        if workshopViewModel.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                .frame(width: BrowseToolbarMetrics.iconButtonWidth)
                .disabled(workshopViewModel.isLoading)
                .accessibilityLabel(workshopViewModel.isLoading ? L("正在刷新创意工坊…") : L("刷新创意工坊"))
                .accessibilityIdentifier("workshop.refresh")
                .help(L("刷新创意工坊"))

                WallpaperGridViewMenu(viewModel: viewModel)
                    .frame(width: BrowseToolbarMetrics.viewMenuWidth)

                Menu {
                    sortOption(.topRated)
                    sortOption(.trending, period: .year)
                    sortOption(.trending, period: .month)
                    sortOption(.trending, period: .week)
                    sortOption(.trending, period: .day)
                    sortOption(.lastUpdated)
                    sortOption(.recentlyReleased)
                    sortOption(.mostSubscribed)
                    if !workshopViewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider()
                        sortOption(.textRelevance)
                    }
                } label: {
                    Text(workshopViewModel.sortOrder.workshopLabel(
                        period: workshopViewModel.trendPeriod
                    ))
                    .lineLimit(1)
                }
                .frame(width: BrowseToolbarMetrics.wideButtonWidth)
                .help(workshopViewModel.sortOrder.workshopLabel(period: workshopViewModel.trendPeriod))
            }
            .frame(width: BrowseToolbarMetrics.actionsWidth)
        }
        .controlSize(.large)
        .frame(height: BrowseToolbarMetrics.height)
    }

    private func sortOption(
        _ order: WorkshopSortOrder,
        period: WorkshopTrendPeriod? = nil
    ) -> some View {
        let activePeriod = period ?? workshopViewModel.trendPeriod
        let isSelected = workshopViewModel.sortOrder == order
            && (period == nil || workshopViewModel.trendPeriod == period)
        return Button {
            workshopViewModel.selectWorkshopSort(order, period: period)
        } label: {
            HStack {
                Text(order.workshopLabel(period: activePeriod))
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}
