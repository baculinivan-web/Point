# Point — Product Vision

> This document describes the product and user experience. Technical implementation details live in [TECHNICAL_DOCUMENTATION.md](./TECHNICAL_DOCUMENTATION.md).

## 1. The idea

Point is a native macOS browser designed to make the browser itself fade into the background. Websites, documents, and web apps deserve the full attention of the window; browser controls should appear when they help and disappear when they do not.

Point uses a sidebar as a quiet map of the user's open work. It organizes tabs without permanently surrounding the page with toolbars and panels.

## 2. Why Point should exist

Modern browsers are capable, but they often make the interface feel like the product. Persistent toolbars, crowded tab strips, recommendations, badges, and constant management compete with the page.

Point takes a different position: the browser is infrastructure for working on the web. It should be fast, calm, predictable, and easy to forget.

## 3. Product promise

**The whole internet is in front of you. The browser appears only when you need it.**

Point should:

- open quickly and respond immediately;
- let the page occupy the available space;
- make open work easy to find and organize;
- feel like a natural part of macOS;
- treat memory, energy, privacy, and accessibility as part of quality;
- remain calm even during a long session with many pages open.

## 4. Audience

Point is for Mac users who spend a meaningful part of their day in the browser and care about the quality of the interface as much as its feature list. It is especially suited to people who want a sidebar and better tab organization without a noisy or resource-heavy experience.

The product should not require a new browser philosophy. Familiar actions must remain familiar, while the benefits of the sidebar should become obvious through use.

## 5. Principles

### Content comes first

The website is the main object in the window. Browser UI must not constantly take height or width away from it.

### The sidebar is the map

The sidebar combines navigation, open pages, and work context. It should be quick, visually quiet, comfortable with a pointer, trackpad, or keyboard, and predictable when shown or hidden.

### Minimalism means less noise

Every persistent element must earn its space. Rare actions belong in menus or command surfaces and should appear near an object when relevant. Minimalism is not a lack of capability; it is a lack of distraction.

### Native without compromise

Point should feel made for Mac: familiar gestures, typography, window behavior, accessibility, and system conventions. Liquid Glass is used to create focus and context, never as decoration that reduces legibility.

### Performance is part of the design

Speed is something users feel. Opening, switching, revealing the sidebar, and returning to work should remain dependable over a long session. Every feature carries a cost in memory, energy, complexity, and attention.

### Motion has a purpose

Animation explains a change of state. It should be quick, interruptible, and connected to the user's action. Motion should never make a repeated action feel slower.

## 6. The central experience

- **Open:** Point shows the last active page or a clean starting state, without a dashboard or setup wizard.
- **Switch:** The sidebar appears without shrinking the page, then recedes when focus returns to the website.
- **Create:** A new page opens directly into one clear field for a website address or search.
- **Disappear:** Once a page is open, the browser can fade from attention while keyboard commands and gestures remain available.
- **Return:** After a restart, Point restores a useful working context without trying to bring every page fully back to life at once.

## 7. What matters in the first version

The first public version should do a small set of daily actions exceptionally well:

1. Open websites quickly.
2. Make open pages easy to navigate through the sidebar.
3. Let the website use the whole window.
4. Keep tabs organized and recoverable.
5. Support familiar navigation, downloads, history, and privacy controls.
6. Restore a useful session without unnecessary resource use.
7. Stay smooth and stable through a long workday.
8. Feel coherent and native on current macOS.

Features that do not strengthen this core can wait.

## 8. Success criteria

Point is succeeding when users can keep it open all day without thinking about it, find an old page quickly, understand where their work is, and feel that the web has more room to breathe.

The product should be judged by focus, recoverability, responsiveness, clarity, and trust—not by the number of controls visible at once.

## 9. Decision rule

When choosing between two directions, prefer the one that gives more attention to the page, reduces repeated management, follows macOS conventions, costs less attention and energy, and remains understandable without explanation.

## 10. Formula

**Point = the web in focus + a sidebar that remembers your work − browser noise.**
