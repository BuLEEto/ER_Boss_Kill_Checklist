// OBS Overlay — SSE live updates + auto-refresh fallback
(function() {
    // SSE for live updates (works with OBS Browser source)
    var evtSource = new EventSource('/events');
    evtSource.addEventListener('boss_update', function() {
        window.location.reload();
    });

    var params = new URLSearchParams(window.location.search);

    // Chroma key background
    var bg = params.get('bg');
    if (bg === 'green' || bg === 'magenta') {
        document.body.classList.add('bg-' + bg);
    }

    // Auto-refresh fallback for OBS Window Capture / old OBS without browser source
    var refreshSec = parseInt(params.get('refresh') || '0', 10);
    if (refreshSec > 0) {
        setInterval(function() {
            window.location.reload();
        }, refreshSec * 1000);
    }
})();
