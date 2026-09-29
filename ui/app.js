const { createApp, reactive, ref, computed } = Vue;

createApp({
  setup() {
    const hostReady = ref(false);
    const isRefreshing = ref(false);
    const selectedItemId = ref('');
    const dragOverItemId = ref('');
    const notice = reactive({ visible: false, level: 'info', message: '' });
    const assignments = reactive({});
    const enabledItems = reactive({});
    const selectedPhotos = reactive({});
    let noticeTimer = null;

    const camera = reactive({ connected: false, testSource: false });
    const template = reactive({ analyzing: false, fileName: '', filePath: '', tables: [], items: [] });
    const photo = reactive({ loading: false, ready: false, requestedCount: 0, poolCount: 0, shortage: 0, photos: [] });
    const marker = reactive({
      active: false,
      loading: false,
      complete: false,
      itemIndex: 0,
      totalItems: 0,
      itemName: '',
      itemGroup: '',
      itemLabel: '',
      baseName: '',
      previewMode: 'thermal',
      previewVersion: 0,
      markers: [],
      minTemperature: '',
      maxTemperature: '',
      canGoPrevious: false
    });
    const journal = reactive({
      generating: false,
      complete: false,
      fileName: '',
      filePath: '',
      itemCount: 0,
      imageCount: 0,
      temperatureCount: 0,
      cleanupWarning: ''
    });

    const matchingReady = computed(() => template.items.length > 0 && photo.ready);
    const currentStep = computed(() => marker.active ? 3 : (matchingReady.value ? 2 : 1));
    const photoById = computed(() => new Map(photo.photos.map(item => [item.id, item])));
    const usedPhotoIds = computed(() => new Set(Object.values(assignments)));
    const poolPhotos = computed(() => photo.photos.filter(item => !usedPhotoIds.value.has(item.id)));
    const enabledCount = computed(() => template.items.filter(item => isItemEnabled(item.id)).length);
    const matchedCount = computed(() => template.items.filter(item => isItemEnabled(item.id) && assignments[item.id]).length);
    const canContinue = computed(() => enabledCount.value > 0 && matchedCount.value === enabledCount.value);
    const groupedPoolPhotos = computed(() => groupPhotosByDate(poolPhotos.value));
    const selectedPhotoCount = computed(() => photo.photos.filter(item => isPhotoSelected(item.id)).length);

    function postMessage(type, payload = {}) {
      if (window.chrome?.webview) window.chrome.webview.postMessage({ type, ...payload });
      else showNotice('error', '프로그램과 화면이 연결되지 않았습니다.');
    }

    function refreshDevice() {
      isRefreshing.value = true;
      postMessage('refresh-device');
      setTimeout(() => { isRefreshing.value = false; }, 2500);
    }

    function selectTemplate() {
      postMessage('select-template');
    }

    function confirmMatching() {
      if (!canContinue.value) return;
      postMessage('confirm-matching', {
        enabledItemIds: template.items.filter(item => isItemEnabled(item.id)).map(item => item.id),
        assignments: { ...assignments }
      });
    }

    function markerPreviewUrl() {
      return `https://thermal-session.local/preview/current.png?v=${marker.previewVersion}`;
    }

    function addMarker(event) {
      if (marker.loading || marker.complete) return;
      const rect = event.currentTarget.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      const x = Math.max(0, Math.min(479, (event.clientX - rect.left) * 479 / rect.width));
      const y = Math.max(0, Math.min(359, (event.clientY - rect.top) * 359 / rect.height));
      marker.loading = true;
      postMessage('marker-add', { x, y });
    }

    function clearMarkers() {
      if (marker.loading || marker.complete) return;
      marker.loading = true;
      postMessage('marker-clear');
    }

    function toggleMarkerPreview() {
      if (marker.loading || marker.complete) return;
      marker.loading = true;
      postMessage('marker-toggle-preview');
    }

    function saveMarkerAndNext() {
      if (marker.loading || marker.complete) return;
      if (!marker.markers.length) {
        showNotice('warning', '온도마커를 하나 이상 표시해 주세요.');
        return;
      }
      marker.loading = true;
      postMessage('marker-save-next');
    }

    function openPreviousMarkerItem() {
      if (marker.loading || marker.complete || !marker.canGoPrevious) return;
      marker.loading = true;
      postMessage('marker-previous');
    }

    function generateJournal() {
      if (journal.generating || journal.complete) return;
      journal.generating = true;
      postMessage('generate-journal');
    }

    function openResultFile() {
      postMessage('open-result-file');
    }

    function openResultFolder() {
      postMessage('open-result-folder');
    }

    function startNewWork() {
      postMessage('new-work');
    }

    function resetApplicationState() {
      template.analyzing = false;
      template.fileName = '';
      template.filePath = '';
      template.tables = [];
      template.items = [];
      photo.loading = false;
      photo.ready = false;
      photo.photos = [];
      marker.active = false;
      marker.loading = false;
      marker.complete = false;
      marker.itemIndex = 0;
      marker.markers = [];
      journal.generating = false;
      journal.complete = false;
      journal.fileName = '';
      journal.filePath = '';
      journal.cleanupWarning = '';
      resetMatchingState();
      resetPhotoSelection();
    }

    function applyMarkerState(message) {
      marker.active = true;
      marker.loading = false;
      marker.complete = false;
      marker.itemIndex = Number(message.itemIndex || 0);
      marker.totalItems = Number(message.totalItems || 0);
      marker.itemName = message.itemName || '';
      marker.itemGroup = message.itemGroup || '';
      marker.itemLabel = message.itemLabel || message.itemName || '';
      marker.baseName = message.baseName || '';
      marker.previewMode = message.previewMode || 'thermal';
      marker.previewVersion = Number(message.previewVersion || 0);
      marker.markers = Array.isArray(message.markers) ? message.markers : [];
      marker.minTemperature = message.minTemperature || '';
      marker.maxTemperature = message.maxTemperature || '';
      marker.canGoPrevious = Boolean(message.canGoPrevious);
    }

    function resetMatchingState() {
      Object.keys(assignments).forEach(key => delete assignments[key]);
      Object.keys(enabledItems).forEach(key => delete enabledItems[key]);
      template.items.forEach(item => { enabledItems[item.id] = true; });
      selectedItemId.value = '';
    }

    function isItemEnabled(itemId) {
      return enabledItems[itemId] !== false;
    }

    function setItemEnabled(itemId, enabled) {
      enabledItems[itemId] = enabled;
      if (!enabled) removeAssignment(itemId);
    }

    function assignedPhoto(itemId) {
      return photoById.value.get(assignments[itemId]) || null;
    }

    function resetPhotoSelection() {
      Object.keys(selectedPhotos).forEach(key => delete selectedPhotos[key]);
    }

    function isPhotoSelected(photoId) {
      return selectedPhotos[photoId] === true;
    }

    function setPhotoSelected(photoId, selected) {
      selectedPhotos[photoId] = selected;
    }

    function dateSelectionState(photos) {
      if (!photos.length) return 'none';
      const selectedCount = photos.filter(item => isPhotoSelected(item.id)).length;
      if (selectedCount === 0) return 'none';
      if (selectedCount === photos.length) return 'all';
      return 'partial';
    }

    function toggleDateSelection(photos) {
      const shouldSelect = dateSelectionState(photos) !== 'all';
      photos.forEach(item => setPhotoSelected(item.id, shouldSelect));
    }

    function ownerOfPhoto(photoId) {
      return Object.keys(assignments).find(itemId => assignments[itemId] === photoId) || '';
    }

    function autoAssign() {
      const candidates = photo.photos.filter(item => isPhotoSelected(item.id));
      if (!candidates.length) {
        showNotice('warning', '순서대로 넣을 사진을 먼저 체크해 주세요.');
        return;
      }

      Object.keys(assignments).forEach(key => delete assignments[key]);
      const targets = template.items.filter(item => isItemEnabled(item.id));
      targets.forEach((item, index) => {
        if (candidates[index]) {
          assignments[item.id] = candidates[index].id;
          setPhotoSelected(candidates[index].id, false);
        }
      });
      selectedItemId.value = '';
      if (targets.length > candidates.length) {
        showNotice('warning', `체크한 사진이 ${targets.length - candidates.length}개 부족합니다.`);
      }
    }

    function clearAllAssignments() {
      Object.keys(assignments).forEach(key => delete assignments[key]);
      selectedItemId.value = '';
    }

    function startPhotoDrag(event, photoId, sourceItemId) {
      event.dataTransfer.effectAllowed = 'move';
      event.dataTransfer.setData('application/json', JSON.stringify({ photoId, sourceItemId }));
      event.dataTransfer.setData('text/plain', photoId);
    }

    function readDrag(event) {
      try {
        return JSON.parse(event.dataTransfer.getData('application/json'));
      } catch {
        return { photoId: event.dataTransfer.getData('text/plain'), sourceItemId: '' };
      }
    }

    function dropOnItem(event, targetItemId) {
      event.preventDefault();
      dragOverItemId.value = '';
      if (!isItemEnabled(targetItemId)) return;

      const { photoId, sourceItemId } = readDrag(event);
      if (!photoId || !photoById.value.has(photoId)) return;
      if (sourceItemId === targetItemId) return;

      const owner = ownerOfPhoto(photoId);
      if (owner) delete assignments[owner];
      delete assignments[targetItemId];
      assignments[targetItemId] = photoId;
      setPhotoSelected(photoId, false);
      selectedItemId.value = targetItemId;
    }

    function dropOnPool(event) {
      event.preventDefault();
      const { photoId, sourceItemId } = readDrag(event);
      const owner = sourceItemId || ownerOfPhoto(photoId);
      if (owner) removeAssignment(owner);
    }

    function removeAssignment(itemId) {
      delete assignments[itemId];
      if (selectedItemId.value === itemId) selectedItemId.value = '';
    }

    function selectAssignment(itemId) {
      if (!assignments[itemId]) return;
      selectedItemId.value = selectedItemId.value === itemId ? '' : itemId;
    }

    function thumbnailUrl(fileName) {
      return `https://thermal.local/photo-cache/${encodeURIComponent(fileName || '')}`;
    }

    function groupPhotosByDate(items) {
      const groups = [];
      const index = new Map();
      items.forEach(item => {
        const date = item.captureDate || '';
        if (!index.has(date)) {
          const group = { date, photos: [] };
          index.set(date, group);
          groups.push(group);
        }
        index.get(date).photos.push(item);
      });
      return groups;
    }

    function formatDate(value) {
      if (!value) return '날짜 없음';
      const [year, month, day] = value.split('-');
      return `${year}.${month}.${day}`;
    }

    function showNotice(level, message) {
      notice.level = level || 'info';
      notice.message = message;
      notice.visible = true;
      clearTimeout(noticeTimer);
      noticeTimer = setTimeout(() => { notice.visible = false; }, 4200);
    }

    function handleHostMessage(event) {
      const message = event.data || {};
      switch (message.type) {
        case 'host-ready':
          hostReady.value = true;
          break;
        case 'device-state':
          camera.connected = Boolean(message.connected);
          camera.testSource = Boolean(message.isTestSource);
          isRefreshing.value = false;
          break;
        case 'device-error':
          isRefreshing.value = false;
          showNotice('error', '카메라 연결 상태를 확인하지 못했습니다.');
          break;
        case 'template-analyzing':
          template.analyzing = true;
          photo.ready = false;
          break;
        case 'template-result':
          template.analyzing = false;
          template.fileName = message.fileName || '';
          template.filePath = message.filePath || '';
          template.tables = Array.isArray(message.tables) ? message.tables : [];
          template.items = Array.isArray(message.items) ? message.items : [];
          resetMatchingState();
          break;
        case 'template-error':
          template.analyzing = false;
          showNotice('error', message.message || '양식을 분석하지 못했습니다.');
          break;
        case 'photo-scan-start':
          photo.loading = true;
          break;
        case 'photo-scan-result':
          photo.loading = false;
          photo.ready = true;
          photo.requestedCount = Number(message.requestedCount || 0);
          photo.poolCount = Number(message.poolCount || 0);
          photo.shortage = Number(message.shortage || 0);
          photo.photos = Array.isArray(message.photos) ? message.photos : [];
          resetPhotoSelection();
          if (photo.shortage > 0) showNotice('warning', `사진이 ${photo.shortage}개 부족합니다.`);
          break;
        case 'photo-scan-error':
          photo.loading = false;
          photo.ready = false;
          showNotice('error', message.message || '카메라 사진을 불러오지 못했습니다.');
          break;
        case 'marker-loading':
          marker.active = true;
          marker.loading = true;
          marker.complete = false;
          break;
        case 'marker-stage':
        case 'marker-updated':
          applyMarkerState(message);
          break;
        case 'marker-all-complete':
          marker.active = true;
          marker.loading = false;
          marker.complete = true;
          showNotice('info', message.message || '모든 마커 작업이 완료되었습니다.');
          break;
        case 'journal-generating':
          journal.generating = true;
          break;
        case 'journal-result':
          journal.generating = false;
          journal.complete = true;
          journal.fileName = message.fileName || '';
          journal.filePath = message.filePath || '';
          journal.itemCount = Number(message.itemCount || 0);
          journal.imageCount = Number(message.imageCount || 0);
          journal.temperatureCount = Number(message.temperatureCount || 0);
          journal.cleanupWarning = message.cleanupWarning || '';
          if (journal.cleanupWarning) showNotice('warning', journal.cleanupWarning);
          break;
        case 'journal-error':
          journal.generating = false;
          showNotice('error', message.message || '완성 문서를 만들지 못했습니다.');
          break;
        case 'reset-app':
          resetApplicationState();
          break;
        case 'marker-error':
          marker.loading = false;
          showNotice('error', message.message || '마커 작업을 처리하지 못했습니다.');
          break;
        case 'notice':
          showNotice(message.level, message.message);
          break;
      }
    }

    window.addEventListener('keydown', event => {
      if (event.code === 'Space' && marker.active && !marker.complete) {
        const tagName = document.activeElement?.tagName?.toLowerCase();
        if (tagName !== 'button' && tagName !== 'input' && tagName !== 'textarea') {
          event.preventDefault();
          saveMarkerAndNext();
        }
        return;
      }
      if ((event.key === 'Delete' || event.key === 'Backspace') && selectedItemId.value) {
        event.preventDefault();
        removeAssignment(selectedItemId.value);
      }
    });

    if (window.chrome?.webview) {
      window.chrome.webview.addEventListener('message', handleHostMessage);
      window.chrome.webview.postMessage({ type: 'ui-ready' });
    }

    return {
      hostReady, isRefreshing, camera, template, photo, marker, journal, notice,
      matchingReady, currentStep, poolPhotos, groupedPoolPhotos,
      enabledCount, matchedCount, canContinue, selectedPhotoCount, selectedItemId, dragOverItemId,
      refreshDevice, selectTemplate, confirmMatching, autoAssign, clearAllAssignments,
      isItemEnabled, setItemEnabled, assignedPhoto, startPhotoDrag,
      dropOnItem, dropOnPool, removeAssignment, selectAssignment,
      isPhotoSelected, setPhotoSelected, dateSelectionState, toggleDateSelection,
      thumbnailUrl, formatDate,
      markerPreviewUrl, addMarker, clearMarkers, toggleMarkerPreview,
      saveMarkerAndNext, openPreviousMarkerItem,
      generateJournal, openResultFile, openResultFolder, startNewWork
    };
  }
}).mount('#app');

