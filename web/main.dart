import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:html' as html;
import 'package:dart_mymc/dart_mymc.dart';

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
  List<html.Element> focusScope = [];

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
  
  html.window.onKeyDown.listen(handleKeyDown);
  //setupGamepadPolling();
}

// --- UI Logic ---

void initUI() {
  html.document.getElementById('slot-area-1')?.onClick.listen((_) => openSlot(1));
  html.document.getElementById('slot-area-2')?.onClick.listen((_) => openSlot(2));
  
  html.document.getElementById('create-btn-1')?.onClick.listen((_) => promptCreateCard(1));
  html.document.getElementById('create-btn-2')?.onClick.listen((_) => promptCreateCard(2));
  
  // Export Card
  html.document.getElementById("export-btn-1")?.onClick.listen((_) => exportCard(1));
  html.document.getElementById("export-btn-2")?.onClick.listen((_) => exportCard(2));
  
  setupFileInput(1);
  setupFileInput(2);
  setupImportSaveInput();

  html.document.getElementById('browser-back-btn')?.onClick.listen((_) => showScreen('slot-select'));
  html.document.getElementById('help-trigger')?.onClick.listen((_) => openHelp());
  html.document.getElementById('other-links-trigger')?.onClick.listen((_) => openOtherLinks());
  html.document.getElementById('themes-toggle')?.onClick.listen((_) => openThemes());
  html.document.getElementById('freeze-toggle')?.onClick.listen((_) => toggleAnimation());
  
  html.document.getElementById('import-save-btn')?.onClick.listen((_) => triggerImportSave());

  setupDragAndDrop(1, html.document.getElementById('slot-1')!);
  setupDragAndDrop(2, html.document.getElementById('slot-2')!);
  setupBrowserDrop();

  updateSlotIcons();
}

void setupBrowserDrop() {
  final element = html.document.getElementById('browser-grid')!;
  element.onDragOver.listen((e) {
    e.preventDefault();
    element.classes.add('drag-over');
  });
  element.onDragLeave.listen((_) => element.classes.remove('drag-over'));
  element.onDrop.listen((e) async {
    e.preventDefault();
    element.classes.remove('drag-over');
    final files = e.dataTransfer.files;
    if (files != null && files.isNotEmpty) {
      await loadFiles(state.currentSlotIndex, files);
    }
  });
}

void setupFileInput(int slotIndex) {
  final input = html.document.getElementById('file-input-$slotIndex') as html.FileUploadInputElement;
  input.onChange.listen((event) async {
    final files = input.files;
    if (files != null && files.isNotEmpty) {
      await loadFiles(slotIndex, files);
    }
  });
}

void setupImportSaveInput() {
  final input = html.document.getElementById('import-save-input') as html.FileUploadInputElement;
  input.onChange.listen((event) async {
    final files = input.files;
    if (files != null && files.isNotEmpty) {
      await importSaveFiles(files);
    }
  });
}

void setupDragAndDrop(int slotIndex, html.Element element) {
  element.onDragOver.listen((e) {
    e.preventDefault();
    element.classes.add('drag-over');
  });
  element.onDragLeave.listen((_) => element.classes.remove('drag-over'));
  element.onDrop.listen((e) async {
    e.preventDefault();
    element.classes.remove('drag-over');
    final files = e.dataTransfer.files;
    if (files != null && files.isNotEmpty) {
      await loadFiles(slotIndex, files);
    }
  });
}

Future<void> loadFiles(int slotIndex, List<html.File> files) async {
  final sortedFiles = List<html.File>.from(files);
  sortedFiles.sort((a, b) {
    final aIsCard = a.name.toLowerCase().endsWith('.ps2');
    final bIsCard = b.name.toLowerCase().endsWith('.ps2');
    if (aIsCard && !bIsCard) return -1;
    if (!aIsCard && bIsCard) return 1;
    return 0;
  });

  bool isMulti = sortedFiles.length > 1;
  int count = 0;
  showToast('Importing...', title: '');
  for (final file in sortedFiles) {
    await loadFile(slotIndex, file, silent: isMulti);
    count++;
  }
  
  if (isMulti) {
    showToast('Processed $count files', title: 'Complete');
  }
}

Future<void> importSaveFiles(List<html.File> files) async {
  bool isMulti = files.length > 1;
  int count = 0;
  showToast('Importing...', title: '');
  for (final file in files) {
    await importSaveFile(file);
    count++;
  }
  if (isMulti) {
    showToast('Imported $count saves', title: 'Complete');
  }
}

Future<void> loadFile(int slotIndex, html.File file, {bool silent = false}) async {
  final name = file.name.toLowerCase();
  final reader = html.FileReader();
  reader.readAsArrayBuffer(file);
  await reader.onLoadEnd.first;
  final bytes = reader.result as Uint8List;

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
      if (html.document.getElementById('browser-grid')?.classes.contains('active') == true && state.currentSlotIndex == slotIndex) {
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
      if (html.document.getElementById('browser-grid')?.classes.contains('active') == true && state.currentSlotIndex == slotIndex) {
        openSlot(slotIndex);
      }
      if (!silent) showToast('Imported ${file.name}');
    } catch (e) {
      showToast('Error importing "${file.name}": $e');
    }
  }
}

Future<void> importSaveFile(html.File file) async {
  final card = state.currentCard;
  if (card == null) return;
  
  final reader = html.FileReader();
  reader.readAsArrayBuffer(file);
  await reader.onLoadEnd.first;
  final bytes = reader.result as Uint8List;
  
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
  html.document.getElementById('import-save-input')?.click();
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
          html.document.getElementById('file-input-$n')?.click();
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
  html.document.getElementById('current-slot-title')?.text = 'Slot $n';
  
  renderSaveList(card);
  showScreen('browser-grid');
}

void renderSaveList(Ps2Card card) {
  final list = html.document.getElementById('save-list')!;
  list.innerHtml = '';
  
  final saves = card.listSaves();
  saves.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  
  if (saves.isEmpty) {
    list.setInnerHtml('<div style="grid-column:1/-1;text-align:center;color:#888;margin-top:50px;">Empty</div>', treeSanitizer: html.NodeTreeSanitizer.trusted);
  } else {
    for (int i = 0; i < saves.length; i++) {
      final save = saves[i];
      final div = html.DivElement();
      div.className = 'save-card';
      div.onClick.listen((_) => openSaveMenu(save));
      
      div.setInnerHtml('''
        ${generateMCSVG(state.currentTheme, save.title.isNotEmpty ? save.title.substring(0, 1) : '?', 'grad-save-$i')}
        <div class="save-title">${save.title}</div>
        <div class="save-dir">${save.dirName}</div>
      ''', treeSanitizer: html.NodeTreeSanitizer.trusted);
      list.append(div);
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
  final blob = html.Blob([bytes]);
  final url = html.Url.createObjectUrlFromBlob(blob);
  final a = html.AnchorElement(href: url);
  a.download = filename;
  a.click();
  html.Url.revokeObjectUrl(url);
}

// --- UI Helpers ---

void showScreen(String id) {
  final screens = html.document.querySelectorAll('.screen');
  for (int i = 0; i < screens.length; i++) {
    (screens[i] as html.Element).classes.remove('active');
  }
  html.document.getElementById(id)?.classes.add('active');
  if (id == 'slot-select') {
    setFocusScope('.slot-clickable-area, .create-btn, .export-btn, .header-link, #other-links-trigger, .performance-toggle, .help-btn', priorityId: 'slot-area-${state.currentSlotIndex}');
  } else {
    setFocusScope('.save-card, .back-btn, .create-btn');
  }
}

void updateSlotInfo(int n) {
  final card = (n == 1 ? state.slot1 : state.slot2);
  final status = html.document.getElementById('status-$n')!;
  final bar = html.document.getElementById('cap-bar-$n')!;
  final fill = html.document.getElementById('fill-$n')!;
  final text = html.document.getElementById('cap-text-$n')!;
  
  if (card == null) {
    status.text = 'No Card';
    bar.classes.add('hidden');
    text.classes.add('hidden');
  } else {
    final info = card.info;
    status.text = 'Ready';
    bar.classes.remove('hidden');
    text.classes.remove('hidden');
    
    final percent = (1.0 - (info.freeBytes / info.totalBytes)) * 100;
    fill.style.width = '${percent}%';
    
    final freeMb = info.freeBytes / (1024 * 1024);
    final totalMb = info.totalBytes / (1024 * 1024);
    text.text = '${totalMb.toStringAsFixed(2)} MB Total / ${freeMb.toStringAsFixed(2)} MB Free';
  }
}

extension NumberFormatting on int {
  String toLocaleString() {
    return toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (Match m) => '${m[1]},');
  }
}

void updateSlotIcons() {
  html.document.getElementById('icon-1')!.setInnerHtml(generateMCSVG(state.currentTheme, '1', 'slot1', showLoadHint: state.slot1 == null), treeSanitizer: html.NodeTreeSanitizer.trusted);
  html.document.getElementById('icon-2')!.setInnerHtml(generateMCSVG(state.currentTheme, '2', 'slot2', showLoadHint: state.slot2 == null), treeSanitizer: html.NodeTreeSanitizer.trusted);
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
  html.document.getElementById('modal-title')!.text = title;
  html.document.getElementById('modal-body')!.setInnerHtml('<p style="text-align:center; color:#ccc; margin: 20px 0;">$body</p>', treeSanitizer: html.NodeTreeSanitizer.trusted);
  
  final btnContainer = html.document.getElementById('modal-buttons')!;
  btnContainer.innerHtml = '';
  
  if (buttons != null) {
    for (final btn in buttons) {
      final b = html.ButtonElement();
      b.className = 'modal-btn';
      if (btn.isDanger) b.style.color = '#ff4444';
      if (btn.disabled) {
        b.disabled = true;
        b.style.opacity = '0.5';
        b.style.cursor = 'default';
      } else {
        b.onClick.listen((_) => btn.action());
      }
      b.text = btn.label;
      btnContainer.append(b);
    }
  }
  
  html.document.getElementById('modal-footer-dynamic')!.setInnerHtml('''
    <div class="modal-footer">
      <div class="nav-hint" id="modal-back-hint">
        <svg class="btn-icon-small" viewBox="0 0 50 50"><circle cx="25" cy="25" r="20" fill="none" stroke="#ff4444" stroke-width="6"/></svg>
        <span>Back</span>
      </div>
    </div>
  ''', treeSanitizer: html.NodeTreeSanitizer.trusted);
  
  html.document.getElementById('modal-back-hint')?.onClick.listen((_) => closeModal());
  html.document.getElementById('modal-overlay')!.style.display = 'flex';
  
  setFocusScope('.modal-btn, .sample-item, .nav-hint');
}

void closeModal() {
  html.document.getElementById('modal-overlay')!.style.display = 'none';
  if (html.document.getElementById('browser-grid')?.classes.contains('active') == true) {
    setFocusScope('.save-card, .back-btn, .create-btn');
  } else {
    setFocusScope('.slot-clickable-area, .create-btn, .export-btn, .header-link, #other-links-trigger, .performance-toggle, .help-btn', priorityId: 'slot-area-${state.currentSlotIndex}');
  }
}

void showToast(String message, {String title = 'Notification'}) {
  final titleEl = html.document.getElementById('modal-title')!;
  if (title == 'Notification' || title.isEmpty) {
    titleEl.text = '';
  } else {
    titleEl.text = title;
  }
  html.document.getElementById('modal-body')!.setInnerHtml('<p style="text-align:center; color:var(--ps2-blue); margin: 20px 0;">$message</p>', treeSanitizer: html.NodeTreeSanitizer.trusted);
  html.document.getElementById('modal-buttons')!.innerHtml = '';
  html.document.getElementById('modal-footer-dynamic')!.innerHtml = '';
  html.document.getElementById('modal-overlay')!.style.display = 'flex';
  Timer(const Duration(milliseconds: 1500), closeModal);
}

// --- Navigation & Accessibility ---

void handleKeyDown(html.KeyboardEvent e) {
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
      state.focusScope[state.focusIndex].click();
    }
  } else if (e.key == 'Escape' || e.key == 'Backspace') {
    if (html.document.getElementById('modal-overlay')!.style.display == 'flex') {
      closeModal();
    } else if (html.document.getElementById('browser-grid')?.classes.contains('active') == true) {
      showScreen('slot-select');
    }
  }
}

void setFocusScope(String selector, {String? priorityId}) {
  Timer(const Duration(milliseconds: 50), () {
    final results = html.document.querySelectorAll(selector);
    final List<html.Element> elements = [];
    
    for (int i = 0; i < results.length; i++) {
      final node = results[i];
      if (node is html.Element && node.offsetParent != null) {
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
    state.focusScope[i].classes.remove('focused');
  }
  if (state.focusIndex < state.focusScope.length) {
    final el = state.focusScope[state.focusIndex];
    el.classes.add('focused');
    el.scrollIntoView(html.ScrollAlignment.CENTER);
  }
}

void setupGamepadPolling() {
  Timer.periodic(const Duration(milliseconds: 150), (_) {
    try {
      final gamepads = html.window.navigator.getGamepads();
      if (gamepads == null) return;
      
      for (int i = 0; i < gamepads.length; i++) {
        final gp = gamepads[i];
        if (gp == null) continue;
        // Gamepad polling logic can be added here
      }
    } catch (e) {
      // Silence periodic errors
    }
  });
}

// --- Background System ---

late html.CanvasElement bgCanvas;
late html.CanvasRenderingContext2D ctx;
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
  final canvas = html.document.getElementById('bg-canvas');
  if (canvas == null) return;
  bgCanvas = canvas as html.CanvasElement;
  ctx = bgCanvas.getContext('2d') as html.CanvasRenderingContext2D;
  resize();
  html.window.onResize.listen((_) => resize());
  
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
  
  html.window.requestAnimationFrame(animate);
}

void resize() {
  bgCanvas.width = html.window.innerWidth ?? 800;
  bgCanvas.height = html.window.innerHeight ?? 600;
}

void animate(num _) {
  if (!state.animationPaused) {
    time += 1;
    ctx.clearRect(0, 0, bgCanvas.width ?? 0, bgCanvas.height ?? 0);
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
  html.window.requestAnimationFrame(animate);
}

({double x, double y, double scale}) project(double x, double y, double z) {
  const fov = 600.0;
  final scale = fov / (fov + z);
  return (
    x: x * scale + (bgCanvas.width ?? 0) / 2,
    y: y * scale + (bgCanvas.height ?? 0) / 2,
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
  
  ctx.strokeStyle = 'rgba(0, 170, 255, ${0.1 + (1 - b.z / 2000) * 0.4})';
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
  final clock = html.document.getElementById('live-clock');
  if (clock == null) return;
  final n = DateTime.now();
  final pad = (int v) => v.toString().padLeft(2, '0');
  clock.text = '${n.year}/${pad(n.month)}/${pad(n.day)} ${pad(n.hour)}:${pad(n.minute)}:${pad(n.second)}';
}

void openThemes() {
  showModal(
    title: 'Select Theme',
    body: 'Select a theme for the Memory Cards:',
    buttons: null,
  );
  
  html.document.getElementById('modal-body')!.setInnerHtml('''
    <div class="icon-sample-grid">
      <div class="sample-item" id="theme-classic">${generateMCSVG('classic', 'C', 'theme-c')}<span>Translucent</span></div>
      <div class="sample-item" id="theme-cyber">${generateMCSVG('cyber', 'M', 'theme-m')}<span>Matte</span></div>
      <div class="sample-item" id="theme-stealth">${generateMCSVG('stealth', 'S', 'theme-s')}<span>Stealth</span></div>
      <div class="sample-item" id="theme-holo">${generateMCSVG('holo', 'H', 'theme-h')}<span>Holo</span></div>
    </div>
  ''', treeSanitizer: html.NodeTreeSanitizer.trusted);
  
  html.document.getElementById('theme-classic')?.onClick.listen((_) => setTheme('classic'));
  html.document.getElementById('theme-cyber')?.onClick.listen((_) => setTheme('cyber'));
  html.document.getElementById('theme-stealth')?.onClick.listen((_) => setTheme('stealth'));
  html.document.getElementById('theme-holo')?.onClick.listen((_) => setTheme('holo'));
  
  setFocusScope('.sample-item, .nav-hint');
}

void setTheme(String theme) {
  state.currentTheme = theme;
  updateSlotIcons();
  if (html.document.getElementById('browser-grid')?.classes.contains('active') == true) {
    openSlot(state.currentSlotIndex);
  }
  showToast('Applied Theme');
}

void toggleAnimation() {
  state.animationPaused = !state.animationPaused;
  html.document.getElementById('freeze-toggle')!.text = state.animationPaused ? 'Animate BG' : 'Freeze';
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
];

void openHostedMenu(int slotIndex) {
  showModal(
    title: 'Hosted Save Packs',
    body: 'Select a save pack to load into Slot $slotIndex:',
    buttons: null,
  );
  
  final body = html.document.getElementById('modal-body')!;
  final listHtml = hostedCards.map((card) => 
    '<div class="modal-btn hosted-item" style="text-align:center; margin-bottom:5px; cursor:pointer;" data-url="${card.url}" data-size="${card.sizeMb}" data-label="${card.label}">${card.label} (${card.sizeMb}MB)</div>'
  ).join('');
  
  body.setInnerHtml('<div style="display:flex; flex-direction:column; gap:10px; padding:10px;">$listHtml</div>', treeSanitizer: html.NodeTreeSanitizer.trusted);
  
  // Add listeners to the dynamic buttons
  final items = html.document.querySelectorAll('.hosted-item');
  for (int i = 0; i < items.length; i++) {
    final el = items[i] as html.Element;
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
    final response = await html.HttpRequest.request(info.url, responseType: 'arraybuffer');
    final bytes = (response.response as ByteBuffer).asUint8List();
    
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
  ('PS2 Emulator', 'https://pcsx2.net/'),
  ('XBOX Memory Card Manager', 'https://bad-al.github.io/xbmut_web/'),
  ('NFL2K5 Save Editor', 'https://bad-al.github.io/nfl2k5tool_web/'),
  
];

void openOtherLinks() {
  showModal(
    title: 'Other Links',
    body: 'Useful resources and links:',
    buttons: null,
  );
  
  final body = html.document.getElementById('modal-body')!;
  final listHtml = otherLinks.map((link) => 
    '<div class="modal-btn" onclick="window.open(\'${link.$2}\', \'_blank\')" style="text-align:center; margin-bottom:5px; cursor:pointer;">${link.$1}</div>'
  ).join('');
  
  body.setInnerHtml('<div style="display:flex; flex-direction:column; gap:10px; padding:10px;">$listHtml</div>', treeSanitizer: html.NodeTreeSanitizer.trusted);
  
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
