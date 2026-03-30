// Mobile Boss Checklist
(function() {
    // Region expand/collapse
    document.querySelectorAll('.region-header').forEach(function(header) {
        header.addEventListener('click', function() {
            var bosses = this.nextElementSibling;
            if (bosses) {
                bosses.classList.toggle('expanded');
            }
        });
    });

    // Progress bar
    var fill = document.getElementById('progress-fill');
    if (fill) {
        var header = document.querySelector('.remaining');
        if (header) {
            var match = header.textContent.match(/\((\d+)\/(\d+)\)/);
            if (match) {
                var killed = parseInt(match[1], 10);
                var total = parseInt(match[2], 10);
                if (total > 0) {
                    fill.style.width = (killed / total * 100) + '%';
                }
            }
        }
    }

    // SSE for live updates
    var evtSource = new EventSource('/events');
    evtSource.addEventListener('boss_update', function() {
        window.location.reload();
    });
})();
