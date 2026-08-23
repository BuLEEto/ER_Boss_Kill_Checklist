// OBS Overlay — SSE live updates + auto-refresh fallback
(function() {
    var params = new URLSearchParams(window.location.search);

    // The page updates by reloading, which is fine for numbers and fatal
    // for an animation — a reload halfway through the kill banner cuts it
    // off. So a reload that arrives while a banner is playing is held
    // back until it has finished.
    var bannerUntil = 0;
    var reloadPending = false;

    function reloadNow() {
        reloadPending = false;
        window.location.reload();
    }

    function reloadOrDefer() {
        if (Date.now() < bannerUntil) {
            reloadPending = true;
            return;
        }
        reloadNow();
    }

    var evtSource = new EventSource('/events');

    evtSource.addEventListener('boss_update', function() {
        reloadOrDefer();
    });

    // Sent just before boss_update, so this always arrives first and the
    // deferral above is already armed by the time the update lands.
    evtSource.addEventListener('boss_killed', function(e) {
        var data;
        try {
            data = JSON.parse(e.data);
        } catch (err) {
            return;
        }
        showKillBanner(data);
    });

    function showKillBanner(data) {
        var names = (data && data.names) || [];
        if (!names.length) return;

        var seconds = (data && data.seconds) || 6;
        var holdMs = seconds * 1000;
        // Long enough for the exit animation to finish before the reload.
        bannerUntil = Date.now() + holdMs + 500;

        // Only ever one on screen: a second kill inside the window
        // replaces the first rather than stacking two banners.
        var existing = document.querySelector('.kill-banner');
        if (existing) existing.remove();

        var banner = document.createElement('div');
        banner.className = 'kill-banner';

        var title = document.createElement('div');
        title.className = 'kill-banner-title';
        title.textContent = names.length > 1 ? 'Bosses Defeated' : 'Boss Defeated';
        banner.appendChild(title);

        // textContent, not innerHTML — boss names come from the save file
        // by way of the boss list, and this page should never be a place
        // where that turns into markup.
        names.forEach(function(n) {
            var el = document.createElement('div');
            el.className = 'kill-banner-name';
            el.textContent = n;
            banner.appendChild(el);
        });

        var rule = document.createElement('div');
        rule.className = 'kill-banner-rule';
        banner.appendChild(rule);

        document.body.appendChild(banner);

        setTimeout(function() {
            banner.classList.add('kill-out');
            setTimeout(function() {
                banner.remove();
                if (reloadPending) reloadNow();
            }, 500);
        }, holdMs);
    }

    // Chroma key background
    var bg = params.get('bg');
    if (bg === 'green' || bg === 'magenta') {
        document.body.classList.add('bg-' + bg);
    }

    // Text alignment. OBS text sources can't align multi-line text at all,
    // so this is the reason to prefer a browser source for lists.
    var align = params.get('align');
    if (align === 'right' || align === 'center') {
        document.body.classList.add('align-' + align);
    }

    // Auto-refresh fallback for OBS Window Capture / old OBS without browser source
    // -----------------------------------------------------------------------
    // Size reporting
    //
    // The card is width:100%, so it fills whatever browser source it's given
    // and its own natural size is invisible from outside. That's what leaves
    // a source box bigger than the card sitting inside it — OBS has no idea
    // how big the card wanted to be. So measure it and tell the app, which
    // shows the numbers in the OBS tab and can size a browser source to match.
    //
    // The page reloads on every update, so this runs again whenever the
    // content changes and a fitted source follows along.
    // -----------------------------------------------------------------------

    function measureNatural() {
        var card = document.querySelector('.overlay');
        if (!card) return null;

        // max-content is the width the card would take if nothing constrained
        // it. Set, measure, put back — the visible card is still meant to
        // fill the source it ends up in.
        var prevWidth = card.style.width;
        var prevMaxWidth = card.style.maxWidth;
        card.style.width = 'max-content';
        card.style.maxWidth = 'none';
        var rect = card.getBoundingClientRect();
        var size = { w: Math.ceil(rect.width), h: Math.ceil(rect.height) };
        card.style.width = prevWidth;
        card.style.maxWidth = prevMaxWidth;

        return (size.w && size.h) ? size : null;
    }

    // The banner is position:fixed against the bottom of the source, so a
    // source fitted tightly to the card would print the two on top of each
    // other. Measure what the banner needs at the card's natural width so the
    // app can leave room for it rather than guessing.
    function measureBanner(width) {
        var probe = document.createElement('div');
        probe.className = 'kill-banner';
        probe.style.cssText =
            'visibility:hidden;animation:none;position:absolute;' +
            'top:0;bottom:auto;left:0;right:auto;width:' + width + 'px';

        var title = document.createElement('div');
        title.className = 'kill-banner-title';
        title.textContent = 'Boss Defeated';
        probe.appendChild(title);

        // One line's worth. A two-line name makes it taller, but sizing for
        // the worst case would leave a permanent gap under every card.
        var name = document.createElement('div');
        name.className = 'kill-banner-name';
        name.textContent = 'Boss Name';
        probe.appendChild(name);

        var rule = document.createElement('div');
        rule.className = 'kill-banner-rule';
        rule.style.animation = 'none';
        probe.appendChild(rule);

        document.body.appendChild(probe);
        var height = Math.ceil(probe.getBoundingClientRect().height);
        probe.remove();
        return height;
    }

    function reportSize() {
        var size = measureNatural();
        if (!size) return;

        fetch('/overlay-size', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                width: size.w,
                height: size.h,
                banner_height: measureBanner(size.w)
            })
        }).catch(function() {
            // Opened from a saved copy, or the server has gone away. The
            // overlay still renders; only the fitting stops working.
        });
    }

    // Web fonts change every metric on the page, so measure once they've
    // settled. Browsers without the API get the plain load event, which is
    // where they were measuring before fonts.ready existed anyway.
    if (document.fonts && document.fonts.ready) {
        document.fonts.ready.then(reportSize);
    } else {
        window.addEventListener('load', reportSize);
    }

    var refreshSec = parseInt(params.get('refresh') || '0', 10);
    if (refreshSec > 0) {
        setInterval(reloadOrDefer, refreshSec * 1000);
    }
})();
