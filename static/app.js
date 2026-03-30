// Elden Ring Boss Checklist — Client JS

(function() {
    function getText(id) {
        var el = document.getElementById(id);
        return el ? el.textContent.trim() : '';
    }

    var savePathInput = document.getElementById('save-path');
    var slotSelect = document.getElementById('slot-select');
    var activeSlot = parseInt(getText('cfg-active-slot') || '-1', 10);
    var savedPath = getText('cfg-save-path');
    var totalBosses = parseInt(getText('cfg-total-bosses') || '0', 10);
    var killedCount = parseInt(getText('cfg-killed-count') || '0', 10);

    var pollSeconds = getText('cfg-poll-seconds') || '3';

    // Set initial save path value
    if (savedPath && savePathInput) {
        savePathInput.value = savedPath;
    }

    // Set poll rate dropdown
    var pollRate = document.getElementById('poll-rate');
    if (pollRate) {
        pollRate.value = pollSeconds;
    }

    // Load character slots for a save file path
    function loadSlots() {
        var path = savePathInput ? savePathInput.value.trim() : '';
        if (!path) return;

        fetch('/api/slots?path=' + encodeURIComponent(path))
            .then(function(r) { return r.json(); })
            .then(function(data) {
                if (!slotSelect) return;
                slotSelect.innerHTML = '<option value="-1">-- Select Slot --</option>';
                if (data.slots && data.slots.length > 0) {
                    data.slots.forEach(function(s) {
                        var opt = document.createElement('option');
                        opt.value = s.index;
                        opt.textContent = s.name + ' (Lv ' + s.level + ')';
                        if (s.index === activeSlot) opt.selected = true;
                        slotSelect.appendChild(opt);
                    });
                } else {
                    var opt = document.createElement('option');
                    opt.value = '-1';
                    opt.textContent = 'No active characters found';
                    slotSelect.appendChild(opt);
                }
            })
            .catch(function() {});
    }

    if (savePathInput && savePathInput.value) loadSlots();

    // Region collapse toggling
    document.querySelectorAll('.region-header').forEach(function(header) {
        header.addEventListener('click', function() {
            this.parentElement.classList.toggle('collapsed');
        });
    });

    // File browser
    var modal = document.getElementById('file-modal');
    var browseBtn = document.getElementById('browse-btn');
    var closeBtn = document.getElementById('modal-close-btn');

    if (browseBtn) {
        browseBtn.addEventListener('click', function() {
            if (modal) modal.style.display = 'flex';
            browseTo('');
        });
    }

    if (closeBtn) {
        closeBtn.addEventListener('click', closeBrowser);
    }

    if (modal) {
        modal.addEventListener('click', function(e) {
            if (e.target === modal) closeBrowser();
        });
    }

    function closeBrowser() {
        if (modal) modal.style.display = 'none';
    }

    function browseTo(path) {
        fetch('/api/browse?path=' + encodeURIComponent(path))
            .then(function(r) {
                if (!r.ok) throw new Error('HTTP ' + r.status);
                return r.json();
            })
            .then(function(data) {
                if (data.error) throw new Error(data.error);
                var pathEl = document.getElementById('modal-path');
                var container = document.getElementById('modal-entries');
                if (pathEl) pathEl.textContent = data.path;
                if (!container) return;
                container.innerHTML = '';

                data.entries.forEach(function(entry) {
                    var div = document.createElement('div');
                    div.className = 'browse-entry';

                    if (entry.is_dir) {
                        div.textContent = entry.name;
                        div.insertAdjacentHTML('afterbegin', '<span class="browse-icon">&#128193;</span> ');
                        div.addEventListener('click', function() {
                            browseTo(data.path + (data.sep || '/') + entry.name);
                        });
                    } else {
                        div.textContent = entry.name;
                        div.insertAdjacentHTML('afterbegin', '<span class="browse-icon">&#128190;</span> ');
                        div.className += ' browse-save';
                        div.addEventListener('click', function() {
                            if (savePathInput) savePathInput.value = data.path + (data.sep || '/') + entry.name;
                            closeBrowser();
                            loadSlots();
                        });
                    }

                    container.appendChild(div);
                });
            })
            .catch(function(err) {
                var container = document.getElementById('modal-entries');
                if (container) container.innerHTML = '<div class="browse-error">Cannot read directory: ' + err.message + '</div>';
            });
    }

    // Scan for saves
    var scanBtn = document.getElementById('scan-btn');
    var scanModal = document.getElementById('scan-modal');
    var scanEntries = document.getElementById('scan-entries');
    var scanCloseBtn = document.getElementById('scan-close-btn');

    var KNOWN_APPS = {
        '1245620': 'Elden Ring',
    };

    function closeScan() {
        if (scanModal) scanModal.style.display = 'none';
    }

    if (scanCloseBtn) scanCloseBtn.addEventListener('click', closeScan);
    if (scanModal) scanModal.addEventListener('click', function(e) {
        if (e.target === scanModal) closeScan();
    });

    if (scanBtn) {
        scanBtn.addEventListener('click', function() {
            scanBtn.textContent = 'Scanning...';
            scanBtn.disabled = true;
            fetch('/api/scan-saves')
                .then(function(r) { return r.json(); })
                .then(function(data) {
                    if (!scanEntries) return;
                    scanEntries.innerHTML = '';

                    if (!data.saves || data.saves.length === 0) {
                        scanEntries.innerHTML = '<div class="scan-empty">No save files found. Use Browse to locate manually.</div>';
                        if (scanModal) scanModal.style.display = 'flex';
                        return;
                    }

                    data.saves.forEach(function(s) {
                        var item = document.createElement('div');
                        item.className = 'scan-item';

                        var appLabel = KNOWN_APPS[s.app_id] || 'Modded/Other';
                        var isModded = !KNOWN_APPS[s.app_id];
                        var appClass = isModded ? 'scan-app-id modded' : 'scan-app-id';

                        var html = '<div class="scan-item-header">';
                        html += '<span><span class="scan-filename">' + s.filename + '</span>';
                        html += '<span class="scan-ext">' + s.ext + '</span></span>';
                        html += '<span class="' + appClass + '">' + appLabel + ' (' + s.app_id + ')</span>';
                        html += '</div>';
                        html += '<div class="scan-path">' + s.path + '</div>';

                        if (s.characters && s.characters.length > 0) {
                            html += '<div class="scan-characters">';
                            s.characters.forEach(function(c) {
                                html += '<span class="scan-char">';
                                html += '<span class="scan-char-name">' + c.name + '</span>';
                                html += '<span class="scan-char-level">Lvl ' + c.level + '</span>';
                                html += '</span>';
                            });
                            html += '</div>';
                        } else {
                            html += '<div class="scan-characters"><span class="scan-char" style="color:var(--text-dim)">No characters</span></div>';
                        }

                        item.innerHTML = html;
                        item.addEventListener('click', function() {
                            if (savePathInput) savePathInput.value = s.path;
                            closeScan();
                            loadSlots();
                        });
                        scanEntries.appendChild(item);
                    });

                    if (scanModal) scanModal.style.display = 'flex';
                })
                .catch(function() {
                    if (scanEntries) {
                        scanEntries.innerHTML = '<div class="scan-empty">Scan failed.</div>';
                    }
                    if (scanModal) scanModal.style.display = 'flex';
                })
                .finally(function() {
                    scanBtn.textContent = 'Scan';
                    scanBtn.disabled = false;
                });
        });
    }

    // Hide completed regions toggle
    var toggleCompletedBtn = document.getElementById('toggle-completed-btn');
    var hideCompleted = false;
    if (toggleCompletedBtn) {
        toggleCompletedBtn.addEventListener('click', function() {
            hideCompleted = !hideCompleted;
            this.textContent = hideCompleted ? 'Show Completed Regions' : 'Hide Completed Regions';
            document.querySelectorAll('.region').forEach(function(region) {
                var countText = region.querySelector('.region-count');
                if (countText) {
                    var parts = countText.textContent.split('/');
                    if (parts.length === 2 && parts[0].trim() === parts[1].trim()) {
                        region.style.display = hideCompleted ? 'none' : '';
                    }
                }
            });
        });
    }

    // Overlay URL builder
    var overlayUrl = document.getElementById('overlay-url');
    var modeBtns = document.querySelectorAll('#mode-btns .mode-btn');
    var countRow = document.getElementById('count-row');
    var regionRow = document.getElementById('region-row');
    var nextCount = document.getElementById('next-count');
    var regionSelect = document.getElementById('region-select');
    var optDeaths = document.getElementById('opt-deaths');
    var optRefresh = document.getElementById('opt-refresh');
    var refreshInterval = document.getElementById('refresh-interval');
    var bgBtns = document.querySelectorAll('#bg-btns .mode-btn');
    var copyBtn = document.getElementById('copy-url-btn');
    var previewBtn = document.getElementById('preview-btn');
    var currentMode = 'summary';
    var currentBg = 'none';

    // Populate region select from DOM
    if (regionSelect) {
        document.querySelectorAll('.region-header h2').forEach(function(h2, i) {
            var opt = document.createElement('option');
            opt.value = i;
            opt.textContent = h2.textContent;
            regionSelect.appendChild(opt);
        });
    }

    function updateOverlayUrl() {
        if (!overlayUrl) return;
        var url = window.location.origin + '/overlay?mode=' + currentMode;
        if (currentMode === 'next' && nextCount) {
            url += '&count=' + nextCount.value;
        }
        if (currentMode === 'region' && regionSelect) {
            url += '&region=' + regionSelect.value;
        }
        if (optDeaths && optDeaths.checked) {
            url += '&deaths=true';
        }
        if (optRefresh && optRefresh.checked && refreshInterval) {
            url += '&refresh=' + refreshInterval.value;
        }
        if (currentBg !== 'none') {
            url += '&bg=' + currentBg;
        }
        overlayUrl.value = url;
    }

    // Mode button toggling
    modeBtns.forEach(function(btn) {
        btn.addEventListener('click', function() {
            modeBtns.forEach(function(b) { b.classList.remove('active'); });
            this.classList.add('active');
            currentMode = this.dataset.mode;

            if (countRow) countRow.style.display = currentMode === 'next' ? '' : 'none';
            if (regionRow) regionRow.style.display = currentMode === 'region' ? '' : 'none';
            updateOverlayUrl();
        });
    });

    if (nextCount) nextCount.addEventListener('change', updateOverlayUrl);
    if (regionSelect) regionSelect.addEventListener('change', updateOverlayUrl);
    if (optDeaths) optDeaths.addEventListener('change', updateOverlayUrl);
    if (optRefresh) {
        optRefresh.addEventListener('change', function() {
            if (refreshInterval) refreshInterval.style.display = optRefresh.checked ? '' : 'none';
            updateOverlayUrl();
        });
    }
    if (refreshInterval) refreshInterval.addEventListener('change', updateOverlayUrl);

    // Background button toggling
    bgBtns.forEach(function(btn) {
        btn.addEventListener('click', function() {
            bgBtns.forEach(function(b) { b.classList.remove('active'); });
            this.classList.add('active');
            currentBg = this.dataset.bg;
            updateOverlayUrl();
        });
    });

    // Copy URL
    if (copyBtn) {
        copyBtn.addEventListener('click', function() {
            if (overlayUrl) {
                overlayUrl.select();
                navigator.clipboard.writeText(overlayUrl.value).then(function() {
                    copyBtn.textContent = 'Copied!';
                    setTimeout(function() { copyBtn.textContent = 'Copy'; }, 1500);
                });
            }
        });
    }

    // Preview overlay
    if (previewBtn) {
        previewBtn.addEventListener('click', function() {
            if (overlayUrl) window.open(overlayUrl.value, '_blank', 'width=360,height=600');
        });
    }

    updateOverlayUrl();

    // OBS Guide toggle
    var guideToggle = document.getElementById('guide-toggle');
    var guideContent = document.getElementById('guide-content');
    if (guideToggle && guideContent) {
        guideToggle.addEventListener('click', function() {
            var arrow = guideToggle.querySelector('.guide-arrow');
            if (guideContent.style.display === 'none') {
                guideContent.style.display = '';
                if (arrow) arrow.classList.add('open');
            } else {
                guideContent.style.display = 'none';
                if (arrow) arrow.classList.remove('open');
            }
        });
    }

    // SSE for live updates
    var evtSource = new EventSource('/events');
    evtSource.addEventListener('boss_update', function() {
        window.location.reload();
    });

    // Progress bar
    var fill = document.getElementById('progress-fill');
    if (fill && totalBosses > 0) {
        fill.style.width = (killedCount / totalBosses * 100) + '%';
    }
})();
