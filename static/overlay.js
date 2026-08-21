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
    var refreshSec = parseInt(params.get('refresh') || '0', 10);
    if (refreshSec > 0) {
        setInterval(reloadOrDefer, refreshSec * 1000);
    }
})();
