# Feed layout A/B

Choose **更多 → 设置 → 界面布局** on a recommendation to switch between
**A · 经典布局** (default) and **B · 沉浸布局**. The choice persists locally.
It applies to shared `DYVideoPage` presentations, including followed videos and
videos opened from grids. Live rooms retain their existing presentation.

B reserves a separate trailing action column with a Liquid Glass capsule grouping like, comment, collect and share,
plus a separate glass More button. On iOS versions before 26, these use the
existing ultra-thin material fallback. B constrains the existing media
container to the remaining width, and overlays author information and the
existing expandable caption on a bottom gradient. It keeps existing action
order, follow badge, navigation handlers, camera avoidance and comment docking.
The existing caption is the available title/description source; no new text or
hashtags are fabricated. Aspect-ratio fitting and crop limits remain those of
the existing player.

The switch changes presentation values on the same page/player subtree. It does
not assign new IDs, replace the feed, change scroll selection, or call playback,
network, cache or preload operations.

## Device verification

- On outer and inner displays, compare A with the original layout.
- While playing midway through a video, switch A → B → A. Confirm the same item,
  progress, like/collect state and caption expansion remain in place.
- In B, check portrait, landscape and image posts; inspect the separate action
  column, text wrapping, camera clearance and top navigation.
- Check all action buttons, author/follow, share, more, caption expansion, seeking,
  double tap, long press, feed paging and comments open/close in both layouts.
- Check inner-screen side comments and folded-screen comment docking.

Swift syntax parsing passed. A simulator build was attempted, but the installed
SDK cannot compile existing Duo APIs (`GeometryProxy.reservedRegions` and the
related environment/layout interfaces in `DouyinDuoLayout.swift`). Full build
and device visual/interaction verification require the project's Duo SDK.
