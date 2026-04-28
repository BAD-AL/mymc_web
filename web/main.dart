import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'package:dart_mymc/dart_mymc.dart';
import 'icon_renderer.dart';

// --- Extension Helpers for Migration ---

extension ElementExtensions on web.Element {
  void addClass(String className) => classList.add(className);
  void removeClass(String className) => classList.remove(className);
  bool hasClass(String className) => classList.contains(className);
  
  set innerHtml(String value) {
    innerHTML = value.toJS;
  }
}

extension EventExtensions on web.EventTarget {
  Stream<web.MouseEvent> get onClick => web.EventStreamProvider<web.MouseEvent>('click').forTarget(this);
  Stream<web.KeyboardEvent> get onKeyDown => web.EventStreamProvider<web.KeyboardEvent>('keydown').forTarget(this);
  Stream<web.Event> get onChange => web.EventStreamProvider<web.Event>('change').forTarget(this);
  Stream<web.DragEvent> get onDragOver => web.EventStreamProvider<web.DragEvent>('dragover').forTarget(this);
  Stream<web.DragEvent> get onDragLeave => web.EventStreamProvider<web.DragEvent>('dragleave').forTarget(this);
  Stream<web.DragEvent> get onDrop => web.EventStreamProvider<web.DragEvent>('drop').forTarget(this);
  Stream<web.MouseEvent> get onMouseEnter => web.EventStreamProvider<web.MouseEvent>('mouseenter').forTarget(this);
  Stream<web.MouseEvent> get onMouseLeave => web.EventStreamProvider<web.MouseEvent>('mouseleave').forTarget(this);
}

extension WindowExtensions on web.Window {
  Stream<web.Event> get onResize => web.EventStreamProvider<web.Event>('resize').forTarget(this);
}

// --- State Management ---

class AppState {
  Ps2Card? slot1;
  Ps2Card? slot2;
  String? slot1Name;
  String? slot2Name;
  int currentSlotIndex = 1; // 1 or 2
  String currentTheme = 'classic';
  bool animationPaused = true;
  int helpPage = 0;
  
  // Navigation State
  int focusIndex = 0;
  List<web.Element> focusScope = [];

  // Live animation state
  Timer? rotationTimer;
  double currentRotation = 25.0;

  Ps2Card? get currentCard => currentSlotIndex == 1 ? slot1 : slot2;
  Ps2Card? get otherCard => currentSlotIndex == 1 ? slot2 : slot1;
  String get currentCardName => (currentSlotIndex == 1 ? slot1Name : slot2Name) ?? 'card_export.ps2';
}

final state = AppState();

// --- Initialization ---

void main() {
  initUI();
  initBackground();
  updateClock();
  Timer.periodic(const Duration(seconds: 1), (_) => updateClock());
  
  setFocusScope('.slot-clickable-area, .create-btn, .export-btn, .header-link, #other-links-trigger, .performance-toggle, .help-btn', priorityId: 'slot-area-1');
  
  web.window.onKeyDown.listen(handleKeyDown);
  //setupGamepadPolling();
}

// --- UI Logic ---

void initUI() {
  web.document.getElementById('slot-area-1')?.onClick.listen((_) => openSlot(1));
  web.document.getElementById('slot-area-2')?.onClick.listen((_) => openSlot(2));
  
  web.document.getElementById('create-btn-1')?.onClick.listen((_) => promptCreateCard(1));
  web.document.getElementById('create-btn-2')?.onClick.listen((_) => promptCreateCard(2));
  
  // Export Card
  web.document.getElementById("export-btn-1")?.onClick.listen((_) => exportCard(1));
  web.document.getElementById("export-btn-2")?.onClick.listen((_) => exportCard(2));
  
  setupFileInput(1);
  setupFileInput(2);
  setupImportSaveInput();

  web.document.getElementById('browser-back-btn')?.onClick.listen((_) => showScreen('slot-select'));
  web.document.getElementById('help-trigger')?.onClick.listen((_) => openHelp());
  web.document.getElementById('other-links-trigger')?.onClick.listen((_) => openOtherLinks());
  web.document.getElementById('themes-toggle')?.onClick.listen((_) => openThemes());
  web.document.getElementById('freeze-toggle')?.onClick.listen((_) => toggleAnimation());
  
  web.document.getElementById('import-save-btn')?.onClick.listen((_) => triggerImportSave());

  setupDragAndDrop(1, web.document.getElementById('slot-1')!);
  setupDragAndDrop(2, web.document.getElementById('slot-2')!);
  setupBrowserDrop();

  updateSlotIcons();
}

void setupBrowserDrop() {
  final element = web.document.getElementById('browser-grid')!;
  element.onDragOver.listen((e) {
    e.preventDefault();
    element.addClass('drag-over');
  });
  element.onDragLeave.listen((_) => element.removeClass('drag-over'));
  element.onDrop.listen((e) async {
    final web.DragEvent de = e as web.DragEvent;
    de.preventDefault();
    element.removeClass('drag-over');
    final dt = de.dataTransfer;
    final files = dt?.files;
    if (files != null && files.length > 0) {
      await loadFiles(state.currentSlotIndex, files);
    }
  });
}

void setupFileInput(int slotIndex) {
  final input = web.document.getElementById('file-input-$slotIndex') as web.HTMLInputElement;
  input.onChange.listen((event) async {
    final files = input.files;
    if (files != null && files.length > 0) {
      await loadFiles(slotIndex, files);
    }
  });
}

void setupImportSaveInput() {
  final input = web.document.getElementById('import-save-input') as web.HTMLInputElement;
  input.onChange.listen((event) async {
    final files = input.files;
    if (files != null && files.length > 0) {
      await importSaveFiles(files);
    }
  });
}

void setupDragAndDrop(int slotIndex, web.Element element) {
  element.onDragOver.listen((e) {
    e.preventDefault();
    element.addClass('drag-over');
  });
  element.onDragLeave.listen((_) => element.removeClass('drag-over'));
  element.onDrop.listen((e) async {
    final web.DragEvent de = e as web.DragEvent;
    de.preventDefault();
    element.removeClass('drag-over');
    final dt = de.dataTransfer;
    final files = dt?.files;
    if (files != null && files.length > 0) {
      await loadFiles(slotIndex, files);
    }
  });
}

Future<void> loadFiles(int slotIndex, web.FileList files) async {
  final List<web.File> fileList = [];
  for (int i = 0; i < files.length; i++) {
    fileList.add(files.item(i)!);
  }
  
  fileList.sort((a, b) {
    final aIsCard = a.name.toLowerCase().endsWith('.ps2');
    final bIsCard = b.name.toLowerCase().endsWith('.ps2');
    if (aIsCard && !bIsCard) return -1;
    if (!aIsCard && bIsCard) return 1;
    return 0;
  });

  bool isMulti = fileList.length > 1;
  int count = 0;
  showToast('Importing...', title: '');
  for (final file in fileList) {
    await loadFile(slotIndex, file, silent: isMulti);
    count++;
  }
  
  if (isMulti) {
    showToast('Processed $count files', title: 'Complete');
  }
}

Future<void> importSaveFiles(web.FileList files) async {
  bool isMulti = files.length > 1;
  int count = 0;
  showToast('Importing...', title: '');
  for (int i = 0; i < files.length; i++) {
    await importSaveFile(files.item(i)!);
    count++;
  }
  if (isMulti) {
    showToast('Imported $count saves', title: 'Complete');
  }
}

Future<void> loadFile(int slotIndex, web.File file, {bool silent = false}) async {
  final name = file.name.toLowerCase();
  
  final arrayBuffer = await file.arrayBuffer().toDart;
  final bytes = arrayBuffer.toDart.asUint8List();

  if (name.endsWith('.ps2')) {
    try {
      final card = Ps2Card.openMemory(bytes);
      if (slotIndex == 1) {
        state.slot1 = card;
        state.slot1Name = file.name;
      } else {
        state.slot2 = card;
        state.slot2Name = file.name;
      }
      updateSlotInfo(slotIndex);
      updateSlotIcons();
      // Refresh browser if active
      if (web.document.getElementById('browser-grid')?.hasClass('active') == true && state.currentSlotIndex == slotIndex) {
        openSlot(slotIndex);
      }
    } catch (e) {
      showToast('Error loading card "${file.name}": $e');
    }
  } else if (name.endsWith('.psu') || name.endsWith('.max') || name.endsWith('.zip') || name.endsWith('.sps') || name.endsWith('.cbs')) {
    final targetCard = slotIndex == 1 ? state.slot1 : state.slot2;
    if (targetCard == null) {
      if (!silent) showToast('Load a card first to import "${file.name}".');
      return;
    }
    try {
      targetCard.importSave(bytes, overwrite: true);
      updateSlotInfo(slotIndex);
      if (web.document.getElementById('browser-grid')?.hasClass('active') == true && state.currentSlotIndex == slotIndex) {
        openSlot(slotIndex);
      }
      if (!silent) showToast('Imported ${file.name}');
    } catch (e) {
      showToast('Error importing "${file.name}": $e');
    }
  }
}

Future<void> importSaveFile(web.File file) async {
  final card = state.currentCard;
  if (card == null) return;
  
  final arrayBuffer = await file.arrayBuffer().toDart;
  final bytes = arrayBuffer.toDart.asUint8List();
  
  try {
    card.importSave(bytes, overwrite: true);
    updateSlotInfo(state.currentSlotIndex);
    openSlot(state.currentSlotIndex);
    showToast('Imported ${file.name}');
  } catch (e) {
    showToast('Error importing "${file.name}": $e');
  }
}

void triggerImportSave() {
  (web.document.getElementById('import-save-input') as web.HTMLInputElement?)?.click();
}

void openSlot(int n) {
  final card = (n == 1 ? state.slot1 : state.slot2);
  if (card == null) {
    showModal(
      title: 'Load Card into Slot $n',
      body: 'How would you like to load a memory card?',
      buttons: [
        ModalButton('Load from Computer', () {
          closeModal();
          (web.document.getElementById('file-input-$n') as web.HTMLInputElement?)?.click();
        }),
        ModalButton('Load from Server', () {
          openHostedMenu(n);
        }),
        ModalButton('Cancel', closeModal, isCancel: true),
      ],
    );
    return;
  }
  
  state.currentSlotIndex = n;
  final titleEl = web.document.getElementById('current-slot-title');
  if (titleEl != null) titleEl.textContent = 'Slot $n';
  
  renderSaveList(card);
  showScreen('browser-grid');
}

void renderSaveList(Ps2Card card) {
  final list = web.document.getElementById('save-list')!;
  list.innerHTML = ''.toJS;
  state.rotationTimer?.cancel();
  
  final saves = card.listSaves();
  saves.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  
  if (saves.isEmpty) {
    list.innerHTML = '<div style="grid-column:1/-1;text-align:center;color:#888;margin-top:50px;">Empty</div>'.toJS;
  } else {
    for (int i = 0; i < saves.length; i++) {
      final save = saves[i];
      final div = web.document.createElement('div') as web.HTMLDivElement;
      div.className = 'save-card';
      div.onClick.listen((_) => openSaveMenu(save));
      
      final iconContainerId = 'icon-container-$i';
      
      div.innerHTML = '''
        <div class="save-icon-3d-container" id="$iconContainerId" style="width:120px; height:120px; display:flex; justify-content:center; align-items:center;">
          ${save.iconData == null ? generateMCSVG(state.currentTheme, save.title.isNotEmpty ? save.title.substring(0, 1) : '?', 'grad-save-$i') : ''}
        </div>
        <div class="save-title">${save.title}</div>
        <div class="save-dir">${save.dirName}</div>
      '''.toJS;
      list.appendChild(div);

      if (save.iconData != null) {
        final container = web.document.getElementById(iconContainerId)!;
        final canvas = web.document.createElement('canvas') as web.HTMLCanvasElement;
        canvas.width = 120;
        canvas.height = 120;
        container.appendChild(canvas);
        
        // Initial Snapshot
        Ps2IconRenderer.renderToCanvas(canvas, save.iconData!);

        // Hover Animation
        div.onMouseEnter.listen((_) {
          state.rotationTimer?.cancel();
          state.currentRotation = 0.0; // Starts from the new renderer default (front-facing)
          state.rotationTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
            state.currentRotation += 2.0; // Spin speed
            Ps2IconRenderer.renderToCanvas(canvas, save.iconData!, rotationAngle: state.currentRotation);
          });
        });

        div.onMouseLeave.listen((_) {
          state.rotationTimer?.cancel();
          // Reset to original snapshot angle
          Ps2IconRenderer.renderToCanvas(canvas, save.iconData!);
        });
      }
    }
  }
}

void promptCreateCard(int n) {
  showModal(
    title: 'Format Card',
    body: 'Select size for Slot $n (All existing data in slot will be lost):',
    buttons: [
      ModalButton('8 MB', () => finishFormat(n, 8)),
      ModalButton('16 MB', () => finishFormat(n, 16)),
      ModalButton('32 MB', () => finishFormat(n, 32)),
      ModalButton('64 MB', () => finishFormat(n, 64)),
      ModalButton('Cancel', closeModal, isCancel: true),
    ],
  );
}

void finishFormat(int n, int sizeMb) {
  showToast('Formatting ${sizeMb}MB Card...');
  Timer(const Duration(milliseconds: 500), () {
    final card = Ps2Card.format(sizeMb: sizeMb);
    if (n == 1) {
      state.slot1 = card;
      state.slot1Name = null;
    } else {
      state.slot2 = card;
      state.slot2Name = null;
    }
    updateSlotInfo(n);
    updateSlotIcons();
    closeModal();
  });
}

void exportCard(int n) {
  final card = (n == 1 ? state.slot1 : state.slot2);
  if (card == null) {
    showToast('No card in slot $n to export.');
    return;
  }
  
  final name = (n == 1 ? state.slot1Name : state.slot2Name) ?? 'card_export.ps2';
  
  showModal(
    title: 'Export Card',
    body: 'Choose export format for Slot $n:',
    buttons: [
      ModalButton('Download .ps2 (Image)', () {
        try {
          final bytes = card.toBytes();
          triggerDownload(name.endsWith('.ps2') ? name : '$name.ps2', bytes);
          closeModal();
        } catch (e) {
          showToast('Error exporting card: $e');
        }
      }),
      ModalButton('Download .zip (Contents)', () {
        try {
          final bytes = card.exportAllZip();
          final zipName = name.replaceAll('.ps2', '') + '.zip';
          triggerDownload(zipName, bytes);
          closeModal();
        } catch (e) {
          showToast('Error exporting zip: $e');
        }
      }),
      ModalButton('Cancel', closeModal, isCancel: true),
    ],
  );
}

void openSaveMenu(Ps2SaveInfo save) {
  final otherIndex = state.currentSlotIndex == 1 ? 2 : 1;
  final otherCardLoaded = state.otherCard != null;
  
  showModal(
    title: save.title,
    body: 'Choose an action for this save:',
    buttons: [
      ModalButton('Copy to Slot $otherIndex', () => executeCopy(save), disabled: !otherCardLoaded),
      ModalButton('Export .psu', () => downloadSave(save, Ps2SaveFormat.psu)),
      ModalButton('Export .max', () => downloadSave(save, Ps2SaveFormat.max)),
      ModalButton('Export .zip', () => downloadSaveZip(save)),
      ModalButton('Delete', () => confirmDelete(save), isDanger: true),
      ModalButton('Back', closeModal, isCancel: true),
    ],
  );
}

void executeCopy(Ps2SaveInfo saveInfo) {
  final source = state.currentCard!;
  final dest = state.otherCard!;
  
  try {
    final psuBytes = source.exportSave(saveInfo.dirName, format: Ps2SaveFormat.psu);
    dest.importSave(psuBytes, overwrite: true);
    updateSlotInfo(state.currentSlotIndex == 1 ? 2 : 1);
    showToast('Copied to Slot ${state.currentSlotIndex == 1 ? 2 : 1}');
    closeModal();
  } catch (e) {
    showToast('Error copying: $e');
  }
}

void confirmDelete(Ps2SaveInfo save) {
  showModal(
    title: 'Confirm Delete',
    body: 'Are you sure you want to delete "${save.title}"?',
    buttons: [
      ModalButton('Delete', () {
        state.currentCard?.deleteSave(save.dirName);
        updateSlotInfo(state.currentSlotIndex);
        openSlot(state.currentSlotIndex);
        closeModal();
        showToast('Deleted', title: 'Deleted');
      }, isDanger: true),
      ModalButton('Cancel', () => openSaveMenu(save), isCancel: true),
    ],
  );
}

void downloadSave(Ps2SaveInfo save, Ps2SaveFormat format) {
  final bytes = state.currentCard!.exportSave(save.dirName, format: format);
  final ext = format.toString().split('.').last;
  triggerDownload('${save.dirName}.$ext', bytes);
}

void downloadSaveZip(Ps2SaveInfo save) {
  final bytes = state.currentCard!.exportSaveZip(save.dirName);
  triggerDownload('${save.dirName}.zip', bytes);
}

void triggerDownload(String filename, Uint8List bytes) {
  final blob = web.Blob([bytes.toJS].toJS);
  final url = web.URL.createObjectURL(blob);
  final a = web.document.createElement('a') as web.HTMLAnchorElement;
  a.href = url;
  a.download = filename;
  a.click();
  web.URL.revokeObjectURL(url);
}

// --- UI Helpers ---

void showScreen(String id) {
  final screens = web.document.querySelectorAll('.screen');
  for (int i = 0; i < screens.length; i++) {
    (screens.item(i) as web.HTMLElement).removeClass('active');
  }
  web.document.getElementById(id)?.addClass('active');
  if (id == 'slot-select') {
    setFocusScope('.slot-clickable-area, .create-btn, .export-btn, .header-link, #other-links-trigger, .performance-toggle, .help-btn', priorityId: 'slot-area-${state.currentSlotIndex}');
  } else {
    setFocusScope('.save-card, .back-btn, .create-btn');
  }
}

void updateSlotInfo(int n) {
  final card = (n == 1 ? state.slot1 : state.slot2);
  final status = web.document.getElementById('status-$n')!;
  final bar = web.document.getElementById('cap-bar-$n')!;
  final fill = web.document.getElementById('fill-$n') as web.HTMLElement;
  final text = web.document.getElementById('cap-text-$n')!;
  
  if (card == null) {
    status.textContent = 'No Card';
    bar.addClass('hidden');
    text.addClass('hidden');
  } else {
    final info = card.info;
    status.textContent = 'Ready';
    bar.removeClass('hidden');
    text.removeClass('hidden');
    
    final percent = (1.0 - (info.freeBytes / info.totalBytes)) * 100;
    fill.style.width = '${percent}%';
    
    final freeMb = info.freeBytes / (1024 * 1024);
    final totalMb = info.totalBytes / (1024 * 1024);
    text.textContent = '${totalMb.toStringAsFixed(2)} MB Total / ${freeMb.toStringAsFixed(2)} MB Free';
  }
}

extension NumberFormatting on int {
  String toLocaleString() {
    return toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},');
  }
}

void updateSlotIcons() {
  web.document.getElementById('icon-1')!.innerHTML = generateMCSVG(state.currentTheme, '1', 'slot1', showLoadHint: state.slot1 == null).toJS;
  web.document.getElementById('icon-2')!.innerHTML = generateMCSVG(state.currentTheme, '2', 'slot2', showLoadHint: state.slot2 == null).toJS;
}

String generateMCSVG(String theme, String label, String gradId, {bool showLoadHint = false}) {
  String stopColor, strokeColor;
  double strokeOpacity;
  
  switch (theme) {
    case 'cyber': stopColor = '#002244'; strokeColor = '#00ffff'; strokeOpacity = 0.8; break;
    case 'stealth': stopColor = '#111111'; strokeColor = '#0088ff'; strokeOpacity = 0.3; break;
    case 'holo': stopColor = '#00aaff'; strokeColor = '#ffffff'; strokeOpacity = 0.6; break;
    default: stopColor = 'rgba(0,100,255,0.4)'; strokeColor = '#00aaff'; strokeOpacity = 0.5; break;
  }
  
  String loadHintHtml = '';
  if (showLoadHint) {
    loadHintHtml = '''
      <text x="50" y="66" font-size="6" fill="$strokeColor" text-anchor="middle" opacity="0.8">DRAG or CLICK</text>
      <text x="50" y="74" font-size="6" fill="$strokeColor" text-anchor="middle" opacity="0.8">TO LOAD</text>
    ''';
  }
  
  return '''
    <svg class="mini-mc" viewBox="0 0 100 130">
      <defs>
        <linearGradient id="$gradId" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" style="stop-color:$stopColor"/>
          <stop offset="100%" style="stop-color:#000"/>
        </linearGradient>
      </defs>
      <rect x="5" y="5" width="90" height="120" rx="8" ry="8" fill="url(#$gradId)" stroke="$strokeColor" stroke-opacity="$strokeOpacity" stroke-width="1.5"/>
      <rect x="15" y="10" width="70" height="15" rx="2" fill="rgba(0,0,0,0.5)"/>
      <text x="50" y="21" font-size="7" fill="$strokeColor" text-anchor="middle" opacity="0.8">MEMORY CARD</text>
      <rect x="15" y="50" width="70" height="55" rx="3" fill="rgba(0,0,0,0.3)" stroke="$strokeColor" stroke-opacity="0.3"/>
      $loadHintHtml
      <text x="50" y="92" font-size="18" fill="$strokeColor" text-anchor="middle">${label.substring(0, 1)}</text>
      <text x="20" y="118" font-size="6" fill="$strokeColor" opacity="0.5">MagicGate</text>
    </svg>
  ''';
}

// --- Modal System ---

class ModalButton {
  final String label;
  final void Function() action;
  final bool isDanger;
  final bool isCancel;
  final bool disabled;
  ModalButton(this.label, this.action, {this.isDanger = false, this.isCancel = false, this.disabled = false});
}

void showModal({required String title, required String body, List<ModalButton>? buttons}) {
  web.document.getElementById('modal-title')!.textContent = title;
  web.document.getElementById('modal-body')!.innerHTML = '<p style="text-align:center; color:#ccc; margin: 20px 0;">$body</p>'.toJS;
  
  final btnContainer = web.document.getElementById('modal-buttons')!;
  btnContainer.innerHTML = ''.toJS;
  
  if (buttons != null) {
    for (final btn in buttons) {
      final b = web.document.createElement('button') as web.HTMLButtonElement;
      b.className = 'modal-btn';
      if (btn.isDanger) b.style.color = '#ff4444';
      if (btn.disabled) {
        b.disabled = true;
        b.style.opacity = '0.5';
        b.style.cursor = 'default';
      } else {
        b.onClick.listen((_) => btn.action());
      }
      b.textContent = btn.label;
      btnContainer.appendChild(b);
    }
  }
  
  web.document.getElementById('modal-footer-dynamic')!.innerHTML = '''
    <div class="modal-footer">
      <div class="nav-hint" id="modal-back-hint">
        <svg class="btn-icon-small" viewBox="0 0 50 50"><circle cx="25" cy="25" r="20" fill="none" stroke="#ff4444" stroke-width="6"/></svg>
        <span>Back</span>
      </div>
    </div>
  '''.toJS;
  
  web.document.getElementById('modal-back-hint')?.onClick.listen((_) => closeModal());
  (web.document.getElementById('modal-overlay') as web.HTMLElement).style.display = 'flex';
  
  setFocusScope('.modal-btn, .sample-item, .nav-hint');
}

void closeModal() {
  (web.document.getElementById('modal-overlay') as web.HTMLElement).style.display = 'none';
  if (web.document.getElementById('browser-grid')?.hasClass('active') == true) {
    setFocusScope('.save-card, .back-btn, .create-btn');
  } else {
    setFocusScope('.slot-clickable-area, .create-btn, .export-btn, .header-link, #other-links-trigger, .performance-toggle, .help-btn', priorityId: 'slot-area-${state.currentSlotIndex}');
  }
}

void showToast(String message, {String title = 'Notification'}) {
  final titleEl = web.document.getElementById('modal-title')!;
  if (title == 'Notification' || title.isEmpty) {
    titleEl.textContent = '';
  } else {
    titleEl.textContent = title;
  }
  web.document.getElementById('modal-body')!.innerHTML = '<p style="text-align:center; color:var(--ps2-blue); margin: 20px 0;">$message</p>'.toJS;
  web.document.getElementById('modal-buttons')!.innerHTML = ''.toJS;
  web.document.getElementById('modal-footer-dynamic')!.innerHTML = ''.toJS;
  (web.document.getElementById('modal-overlay') as web.HTMLElement).style.display = 'flex';
  Timer(const Duration(milliseconds: 1500), closeModal);
}

// --- Navigation & Accessibility ---

void handleKeyDown(web.KeyboardEvent e) {
  if (e.key == 'ArrowRight' || e.key == 'ArrowDown') {
    if (state.focusScope.isNotEmpty) {
      state.focusIndex = (state.focusIndex + 1) % state.focusScope.length;
      updateFocus();
    }
  } else if (e.key == 'ArrowLeft' || e.key == 'ArrowUp') {
    if (state.focusScope.isNotEmpty) {
      state.focusIndex = (state.focusIndex - 1 + state.focusScope.length) % state.focusScope.length;
      updateFocus();
    }
  } else if (e.key == 'Enter') {
    if (state.focusScope.isNotEmpty) {
      (state.focusScope[state.focusIndex] as web.HTMLElement).click();
    }
  } else if (e.key == 'Escape' || e.key == 'Backspace') {
    if ((web.document.getElementById('modal-overlay') as web.HTMLElement).style.display == 'flex') {
      closeModal();
    } else if (web.document.getElementById('browser-grid')?.hasClass('active') == true) {
      showScreen('slot-select');
    }
  }
}

void setFocusScope(String selector, {String? priorityId}) {
  Timer(const Duration(milliseconds: 50), () {
    final results = web.document.querySelectorAll(selector);
    final List<web.Element> elements = [];
    
    for (int i = 0; i < results.length; i++) {
      final node = results.item(i);
      if (node != null && (node as web.HTMLElement).offsetParent != null) {
        elements.add(node);
      }
    }
    
    state.focusScope = elements;
    state.focusIndex = 0;

    if (priorityId != null) {
      for (int i = 0; i < elements.length; i++) {
        if (elements[i].id == priorityId) {
          state.focusIndex = i;
          break;
        }
      }
    }
    
    updateFocus();
  });
}

void updateFocus() {
  for (int i = 0; i < state.focusScope.length; i++) {
    state.focusScope[i].removeClass('focused');
  }
  if (state.focusIndex < state.focusScope.length) {
    final el = state.focusScope[state.focusIndex] as web.HTMLElement;
    el.addClass('focused');
    el.scrollIntoView(web.ScrollIntoViewOptions(block: 'center', inline: 'center'));
  }
}

// --- Background System ---

late web.HTMLCanvasElement bgCanvas;
late web.CanvasRenderingContext2D ctx;
double time = 0;
List<Cube> blocks = [];
List<Prism> prisms = [];

class Cube {
  double x, y, z, size, rotX, rotY, vRotX, vRotY, vSpeed;
  Cube({required this.x, required this.y, required this.z, required this.size, required this.rotX, required this.rotY, required this.vRotX, required this.vRotY, required this.vSpeed});
}

class Prism {
  double angle, length, width, dist, speed;
  Prism({required this.angle, required this.length, required this.width, required this.dist, required this.speed});
}

void initBackground() {
  final canvas = web.document.getElementById('bg-canvas');
  if (canvas == null) return;
  bgCanvas = canvas as web.HTMLCanvasElement;
  ctx = bgCanvas.getContext('2d') as web.CanvasRenderingContext2D;
  resize();
  web.window.onResize.listen((_) => resize());
  
  final rand = math.Random();
  for (int i = 0; i < 12; i++) {
    blocks.add(Cube(
      x: (rand.nextDouble() - 0.5) * 2000,
      y: (rand.nextDouble() - 0.5) * 2000,
      z: rand.nextDouble() * 2000,
      size: 40 + rand.nextDouble() * 60,
      rotX: rand.nextDouble() * math.pi,
      rotY: rand.nextDouble() * math.pi,
      vRotX: (rand.nextDouble() - 0.5) * 0.02,
      vRotY: (rand.nextDouble() - 0.5) * 0.02,
      vSpeed: 1 + rand.nextDouble() * 2,
    ));
  }
  for (int i = 0; i < 16; i++) {
    prisms.add(Prism(
      angle: (i / 16) * math.pi * 2,
      length: 400 + rand.nextDouble() * 300,
      width: 20 + rand.nextDouble() * 20,
      dist: 200 + rand.nextDouble() * 100,
      speed: 0.002 + rand.nextDouble() * 0.003,
    ));
  }
  
  web.window.requestAnimationFrame(animate.toJS);
}

void resize() {
  bgCanvas.width = web.window.innerWidth;
  bgCanvas.height = web.window.innerHeight;
}

void animate(double _) {
  if (!state.animationPaused) {
    time += 1;
    ctx.clearRect(0, 0, bgCanvas.width, bgCanvas.height);
    for (int i = 0; i < prisms.length; i++) {
      drawPrism(prisms[i], time);
    }
    for (int i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      b.z -= b.vSpeed;
      if (b.z < -400) {
        b.z = 2000;
        final rand = math.Random();
        b.x = (rand.nextDouble() - 0.5) * 2000;
        b.y = (rand.nextDouble() - 0.5) * 2000;
      }
      b.rotX += b.vRotX;
      b.rotY += b.vRotY;
      drawCube(b);
    }
  }
  web.window.requestAnimationFrame(animate.toJS);
}

({double x, double y, double scale}) project(double x, double y, double z) {
  const fov = 600.0;
  final scale = fov / (fov + z);
  return (
    x: x * scale + bgCanvas.width / 2,
    y: y * scale + bgCanvas.height / 2,
    scale: scale,
  );
}

void drawCube(Cube b) {
  final points = [
    [-1.0, -1.0, -1.0], [1.0, -1.0, -1.0], [1.0, 1.0, -1.0], [-1.0, 1.0, -1.0],
    [-1.0, -1.0, 1.0], [1.0, -1.0, 1.0], [1.0, 1.0, 1.0], [-1.0, 1.0, 1.0]
  ];
  
  final List<({double x, double y, double scale})> proj = [];
  for (int i = 0; i < points.length; i++) {
    final p = points[i];
    double px = p[0] * b.size, py = p[1] * b.size, pz = p[2] * b.size;
    double x1 = px * math.cos(b.rotY) - pz * math.sin(b.rotY);
    double z1 = px * math.sin(b.rotY) + pz * math.cos(b.rotY);
    double y2 = py * math.cos(b.rotX) - z1 * math.sin(b.rotX);
    double z2 = py * math.sin(b.rotX) + z1 * math.cos(b.rotX);
    proj.add(project(x1 + b.x, y2 + b.y, z2 + b.z));
  }
  
  const lines = [
    [0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]
  ];
  
  ctx.strokeStyle = 'rgba(0, 170, 255, ${0.1 + (1 - b.z / 2000) * 0.4})'.toJS;
  ctx.lineWidth = 2 * (1 - b.z / 2000);
  ctx.beginPath();
  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];
    ctx.moveTo(proj[line[0]].x, proj[line[0]].y);
    ctx.lineTo(proj[line[1]].x, proj[line[1]].y);
  }
  ctx.stroke();
}

void drawPrism(Prism p, double time) {
  final a = p.angle + time * p.speed;
  final x1 = math.cos(a) * p.dist, y1 = math.sin(a) * p.dist, z1 = 500.0;
  final x2 = math.cos(a) * (p.dist + p.length), y2 = math.sin(a) * (p.dist + p.length), z2 = 1400.0;
  final r = p.width;
  final Rx = -math.sin(a), Ry = math.cos(a);
  final Ux = 0.0, Uy = 0.0, Uz = 1.0;
  
  for (int i = 0; i < 6; i++) {
    final t1 = i * math.pi / 3, t2 = ((i + 1) % 6) * math.pi / 3, tM = (i + 0.5) * math.pi / 3;
    final o1x = Rx * r * math.cos(t1) + Ux * r * math.sin(t1);
    final o1y = Ry * r * math.cos(t1) + Uy * r * math.sin(t1);
    final o1z = 0.0 * r * math.cos(t1) + Uz * r * math.sin(t1);
    final o2x = Rx * r * math.cos(t2) + Ux * r * math.sin(t2);
    final o2y = Ry * r * math.cos(t2) + Uy * r * math.sin(t2);
    final o2z = 0.0 * r * math.cos(t2) + Uz * r * math.sin(t2);
    
    final v1 = project(x1 + o1x, y1 + o1y, z1 + o1z);
    final v2 = project(x2 + o1x, y2 + o1y, z2 + o1z);
    final v3 = project(x2 + o2x, y2 + o2y, z2 + o2z);
    final v4 = project(x1 + o2x, y1 + o2y, z1 + o2z);
    
    final cross = (v2.x - v1.x) * (v4.y - v1.y) - (v2.y - v1.y) * (v4.x - v1.x);
    if (cross < 0) continue;
    
    final light = 0.1 + 0.5 * math.max(0, math.sin(tM + math.pi / 4));
    final grad = ctx.createLinearGradient(v1.x, v1.y, v2.x, v2.y);
    grad.addColorStop(0, 'rgba(0,150,255,$light)');
    grad.addColorStop(1, 'rgba(0,150,255,0)');
    ctx.fillStyle = grad;
    ctx.beginPath();
    ctx.moveTo(v1.x, v1.y);
    ctx.lineTo(v2.x, v2.y);
    ctx.lineTo(v3.x, v3.y);
    ctx.lineTo(v4.x, v4.y);
    ctx.closePath();
    ctx.fill();
  }
}

// --- Extras ---

void updateClock() {
  final clock = web.document.getElementById('live-clock');
  if (clock == null) return;
  final n = DateTime.now();
  final pad = (int v) => v.toString().padLeft(2, '0');
  clock.textContent = '${n.year}/${pad(n.month)}/${pad(n.day)} ${pad(n.hour)}:${pad(n.minute)}:${pad(n.second)}';
}

void openThemes() {
  showModal(
    title: 'Select Theme',
    body: 'Select a theme for the Memory Cards:',
    buttons: null,
  );
  
  web.document.getElementById('modal-body')!.innerHTML = '''
    <div class="icon-sample-grid">
      <div class="sample-item" id="theme-classic">${generateMCSVG('classic', 'C', 'theme-c')}<span>Translucent</span></div>
      <div class="sample-item" id="theme-cyber">${generateMCSVG('cyber', 'M', 'theme-m')}<span>Matte</span></div>
      <div class="sample-item" id="theme-stealth">${generateMCSVG('stealth', 'S', 'theme-s')}<span>Stealth</span></div>
      <div class="sample-item" id="theme-holo">${generateMCSVG('holo', 'H', 'theme-h')}<span>Holo</span></div>
    </div>
  '''.toJS;
  
  web.document.getElementById('theme-classic')?.onClick.listen((_) => setTheme('classic'));
  web.document.getElementById('theme-cyber')?.onClick.listen((_) => setTheme('cyber'));
  web.document.getElementById('theme-stealth')?.onClick.listen((_) => setTheme('stealth'));
  web.document.getElementById('theme-holo')?.onClick.listen((_) => setTheme('holo'));
  
  setFocusScope('.sample-item, .nav-hint');
}

void setTheme(String theme) {
  state.currentTheme = theme;
  updateSlotIcons();
  if (web.document.getElementById('browser-grid')?.hasClass('active') == true) {
    openSlot(state.currentSlotIndex);
  }
  showToast('Applied Theme');
}

void toggleAnimation() {
  state.animationPaused = !state.animationPaused;
  final btn = web.document.getElementById('freeze-toggle');
  if (btn != null) btn.textContent = state.animationPaused ? 'Animate BG' : 'Freeze';
}

void openHelp() {
  state.helpPage = 0;
  renderHelp();
}

final helpContent = [
  ('General Usage', 'Welcome to PS2 Card Manager, a .ps2 card image save manager for PCSX2 (based on mymc). Click on a slot to load a card from your computer or from our server library. You can also drag and drop .ps2 files directly onto a slot.'),
  ('Navigation', 'Use Arrow Keys to move selection, Enter to select, and Esc/Backspace to go back.'),
  ('Copying', 'Load cards into both slots to enable copying saves between them. You can also drop .max/.psu save files directly into a card view.'),
];

class HostedCard {
  final String label;
  final int sizeMb;
  final String url;
  const HostedCard(this.label, this.sizeMb, this.url);
}

final hostedCards = [
  HostedCard('PS2 Saves (www.maximummemory.com legacy saves)', 32, 'saves/max_memory_ps2_saves.zip'),
  HostedCard('PS2 Saves (nfl2k5rosters.com legacy saves)', 8, 'saves/nfl2k5rosters_ps2.zip'),
  //HostedCard('Modern NFL2K4, NFL2K5 Saves', 8, 'saves/espn_2k4_2k5_modern.zip'),
];

void openHostedMenu(int slotIndex) {
  showModal(
    title: 'Hosted Save Packs',
    body: 'Select a save pack to load into Slot $slotIndex:',
    buttons: null,
  );
  
  final body = web.document.getElementById('modal-body')!;
  final listHtml = hostedCards.map((card) => 
    '<div class="modal-btn hosted-item" style="text-align:center; margin-bottom:5px; cursor:pointer;" data-url="${card.url}" data-size="${card.sizeMb}" data-label="${card.label}">${card.label} (${card.sizeMb}MB)</div>'
  ).join('');
  
  body.innerHTML = '<div style="display:flex; flex-direction:column; gap:10px; padding:10px;">$listHtml</div>'.toJS;
  
  // Add listeners to the dynamic buttons
  final items = web.document.querySelectorAll('.hosted-item');
  for (int i = 0; i < items.length; i++) {
    final el = items.item(i) as web.HTMLElement;
    el.onClick.listen((_) {
      final label = el.getAttribute('data-label')!;
      final size = int.parse(el.getAttribute('data-size')!);
      final url = el.getAttribute('data-url')!;
      loadHostedCard(slotIndex, HostedCard(label, size, url));
    });
  }

  setFocusScope('.modal-btn, .nav-hint');
}

Future<void> loadHostedCard(int slotIndex, HostedCard info) async {
  showToast('Fetching ${info.label}...', title: 'Loading');
  try {
    // 1. Format new card
    final card = Ps2Card.format(sizeMb: info.sizeMb);
    
    // 2. Fetch Zip bytes
    final xhr = web.XMLHttpRequest();
    xhr.open('GET', info.url);
    xhr.responseType = 'arraybuffer';
    final completer = Completer<Uint8List>();
    xhr.onload = (web.Event e) {
      completer.complete((xhr.response as JSArrayBuffer).toDart.asUint8List());
    }.toJS;
    xhr.onerror = (web.Event e) {
      completer.completeError('XHR Error');
    }.toJS;
    xhr.send();
    
    final bytes = await completer.future;
    
    // 3. Import ZIP into card
    card.importZip(bytes, overwrite: true);
    
    // 4. Update State
    if (slotIndex == 1) {
      state.slot1 = card;
      state.slot1Name = info.label + ".ps2";
    } else {
      state.slot2 = card;
      state.slot2Name = info.label + ".ps2";
    }
    
    updateSlotInfo(slotIndex);
    updateSlotIcons();
    closeModal();
    showToast('Loaded ${info.label}', title: 'Success');
    
    // Open the slot to show contents
    Timer(const Duration(milliseconds: 500), () => openSlot(slotIndex));
    
  } catch (e) {
    showToast('Failed to load hosted card: $e', title: 'Error');
    print('Failed to load hosted card: $e' );
  }
}

final otherLinks = [
  //('Google', 'https://google.com'),
  ('Original mymc', 'https://github.com/ps2dev/mymc'),
  ('Game Faqs saves', 'https://gamefaqs.gamespot.com/ps2/561107-ratchet-and-clank/saves'),
  ('PS2 Emulator', 'https://pcsx2.net/'),
  ('XBOX Memory Card Manager', 'https://bad-al.github.io/xbmut_web/'),
  ('NFL2K5 Save Editor', 'https://bad-al.github.io/nfl2k5tool_web/'),
  ('NFL2K4 Save Editor', 'https://bad-al.github.io/nfl2k4tool_web/'),
  
];

void openOtherLinks() {
  showModal(
    title: 'Other Links',
    body: 'Useful resources and links:',
    buttons: null,
  );
  
  final body = web.document.getElementById('modal-body')!;
  final listHtml = otherLinks.map((link) => 
    '<div class="modal-btn" onclick="window.open(\'${link.$2}\', \'_blank\')" style="text-align:center; margin-bottom:5px; cursor:pointer;">${link.$1}</div>'
  ).join('');
  
  body.innerHTML = '<div style="display:flex; flex-direction:column; gap:10px; padding:10px;">$listHtml</div>'.toJS;
  
  setFocusScope('.modal-btn, .nav-hint');
}

void renderHelp() {
  final content = helpContent[state.helpPage];
  showModal(
    title: content.$1,
    body: content.$2,
    buttons: [
      ModalButton('Prev', () { state.helpPage--; renderHelp(); }, disabled: state.helpPage == 0),
      ModalButton('Next', () { state.helpPage++; renderHelp(); }, disabled: state.helpPage == helpContent.length - 1),
      ModalButton('Close', closeModal, isCancel: true),
    ],
  );
}
