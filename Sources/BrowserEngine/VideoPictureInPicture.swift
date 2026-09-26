import Foundation

/// Installed in every frame so embedded players can be found without reading
/// across iframe origins. The script runs in a WebKit content world isolated
/// from the site's JavaScript.
enum VideoPictureInPicture {
    static func observerScript(handlerName: String) -> String {
        """
        (() => {
          const frameID = crypto.randomUUID?.() || String(Math.random());
          const handler = window.webkit.messageHandlers.\(handlerName);
          const videos = () => Array.from(document.querySelectorAll('video'));
          const mediaElements = () => Array.from(document.querySelectorAll('audio,video'));
          const playing = video => !video.paused && !video.ended &&
            video.readyState >= 2 && video.videoWidth > 0 && video.videoHeight > 0;
          let lastMedia = null;
          const currentMedia = () => {
            const active = mediaElements().find(element =>
              !element.paused && !element.ended && element.readyState >= 2);
            if (active) lastMedia = active;
            return lastMedia?.isConnected ? lastMedia : null;
          };
          let heartbeat;
          let heartbeatDelay = 0;
          const report = (pictureInPictureExited = false) => {
            const currentVideos = videos();
            const hasPlayingVideo = currentVideos.some(playing);
            const hasPictureInPicture = currentVideos.some(video =>
              document.pictureInPictureElement === video ||
              video.webkitPresentationMode === 'picture-in-picture');
            const media = currentMedia();
            const mediaAvailable = !!media && !media.ended;
            const mediaPlaying = mediaAvailable && !media.paused && media.readyState >= 2;
            handler.postMessage({frameID, playing: hasPlayingVideo,
              pictureInPicture: hasPictureInPicture,
              mediaAvailable, mediaPlaying,
              mediaKind: media?.tagName?.toLowerCase() || null,
              mediaEnded: media?.ended || false,
              pictureInPictureExited, pageHidden: false});
            const nextDelay = hasPictureInPicture ? 1000 : mediaAvailable ? 10000 : 0;
            if (nextDelay !== heartbeatDelay) {
              if (heartbeat) window.clearInterval(heartbeat);
              heartbeat = nextDelay ? window.setInterval(report, nextDelay) : undefined;
              heartbeatDelay = nextDelay;
            }
          };
          for (const name of ['play', 'pause', 'ended', 'loadeddata',
                              'emptied', 'enterpictureinpicture',
                              'leavepictureinpicture', 'webkitpresentationmodechanged']) {
            document.addEventListener(name, event => {
              if (name === 'play' && event.target instanceof HTMLMediaElement)
                lastMedia = event.target;
              report(name === 'leavepictureinpicture' ||
                (name === 'webkitpresentationmodechanged' &&
                 event.target?.webkitPresentationMode === 'inline'));
            }, true);
          }
          window.addEventListener('pagehide', () =>
            handler.postMessage({frameID, playing: false, pictureInPicture: false,
              mediaAvailable: false, mediaPlaying: false, mediaKind: null,
              pictureInPictureExited: false, pageHidden: true}));
          window.__pointPictureInPicture = {
            async enter() {
              const candidates = videos().filter(playing).sort((a, b) =>
                b.videoWidth * b.videoHeight - a.videoWidth * a.videoHeight);
              for (const video of candidates) {
                if (document.pictureInPictureElement === video ||
                    video.webkitPresentationMode === 'picture-in-picture') return true;
                if (video.disablePictureInPicture) continue;
                try {
                  if (typeof video.requestPictureInPicture === 'function') {
                    await video.requestPictureInPicture();
                    return document.pictureInPictureElement === video;
                  }
                  if (video.webkitSupportsPresentationMode?.('picture-in-picture') &&
                      typeof video.webkitSetPresentationMode === 'function') {
                    video.webkitSetPresentationMode('picture-in-picture');
                    await new Promise(resolve => setTimeout(resolve, 150));
                    if (video.webkitPresentationMode === 'picture-in-picture') return true;
                  }
                } catch (_) { /* Another playing video may support PiP. */ }
              }
              return false;
            },
            async exit() {
              if (document.pictureInPictureElement) {
                try { await document.exitPictureInPicture(); } catch (_) {}
              }
              for (const video of videos()) {
                if (video.webkitPresentationMode === 'picture-in-picture') {
                  try { video.webkitSetPresentationMode('inline'); } catch (_) {}
                }
              }
              report();
            },
            async toggleMedia() {
              const media = currentMedia();
              if (!media || media.ended) return false;
              try {
                if (media.paused) await media.play();
                else media.pause();
              } catch (_) { return false; }
              report();
              return true;
            }
          };
          report();
        })();
        """
    }

    static let enterScript = "return await window.__pointPictureInPicture?.enter() ?? false;"
    static let exitScript = "await window.__pointPictureInPicture?.exit();"
    static let toggleMediaScript = "return await window.__pointPictureInPicture?.toggleMedia() ?? false;"
}
