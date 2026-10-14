# FMXWayland (кратко по-русски)

Нативная платформа Wayland для Delphi FireMonkey (FMX) под Linux на Object Pascal — без закрытой библиотеки
Embarcadero `libfmux.so` и без GTK. Программа FMX работает с композитором Wayland напрямую (libwayland-client и
libxkbcommon загружаются через `dlopen`) и рисует в буферы общей памяти (wl_shm) стандартным канвасом FMX для Linux
(cairo и Pango, как с libfmux) или, по желанию, Skia-канвасом.

**Как это устроено.** FMX для Linux вызывает libfmux через ~186 указателей на функции модуля `FMUX.Api`.
Прекомпилированные модули FMX принимают другой `FMUX.Api` с тем же интерфейсом, поэтому `tools\gen-fmux-api.ps1`
при сборке генерирует его: секция interface копируется из установленной Delphi (это код Embarcadero, в репозиторий
не попадает), секция implementation наша — заглушки для всех функций и назначение реализованных из
`FMXWayland.Fmux`. Логика `FMX.Platform.Linux` остаётся embarcaderовской. Протоколы Wayland переводятся в Pascal
своим сканером `tools\gen-wayland.ps1`.

**Что работает (фаза 1):** окна (xdg_toplevel), всплывающие окна (xdg_popup: списки комбобоксов, popup-меню),
мышь, колесо, клавиатура (xkbcommon, автоповтор, dead keys, любые раскладки, сочетания по позиции клавиш), курсоры,
буфер обмена (текст), таймеры, `TThread.Synchronize`, модальные формы, окна сообщений, диалоги файлов,
развернуть/восстановить,
закрытие композитором, HiDPI-масштаб (целый и дробный, wp-fractional-scale-v1), xdg-activation, собственные
декорации окна (заголовок с кнопками, которые предлагает оконный менеджер, перемещение, изменение размера), если
композитор не рисует их сам (WSLg, Weston, GNOME, sway с `border csd`). Проверено на WSLg (тест с настоящим вводом с
Windows: `tests\hello-e2e.ps1`), на headless Weston 14 с масштабом 1 и 2 (`tests\weston-headless.ps1`), на Weston 9,
10 и 15 в контейнерах Ubuntu 22.04, Debian 12, Fedora 44 (`tests\glibc-compat.ps1`) и на sway 1.11, KWin 6.6,
GNOME Shell 50 без экрана с масштабом 1, 2 и 1,5 с вводом, буфером обмена с другим приложением и скриншотами
(`tests\compositors.ps1`, таблица в README.md, раздел «Compositors»).

**Канвасы.** Стандартный канвас FMX (`FMX.Canvas.Linux`) работает через функции канваса, текста и кодеков FMUX,
реализованные в `FMXWayland.Cairo` на системных cairo, Pango и gdk-pixbuf (их прислал [Hemul GM](https://github.com/HemulGM), спасибо!); FMX
перерисовывает только изменённую область сохранённого кадра окна. Skia — по желанию: `FMX.Skia` и
`GlobalUseSkia := True` в программе, `libsk4d.so` рядом с ней.

**Диалоги.** `TOpenDialog`, `TSaveDialog`, `SelectDirectory` и синхронные окна сообщений FMX идут в заменяемый
бэкенд (`FMXWayland.Dialogs`, интерфейс `IFMXWaylandDialogBackend`). По умолчанию диалоги файлов показывает сам
рабочий стол через xdg-desktop-portal (`org.freedesktop.portal.FileChooser`: GNOME, KDE, GTK) — по собственному
маленькому клиенту D-Bus на Pascal (`FMXWayland.DBus`, без libdbus). Окно программы экспортируется через
xdg-foreign, и диалог портала становится его дочерним окном; пока он открыт, цикл программы работает (отрисовка,
таймеры), а её окна не принимают ввод, как под модальной формой. Если портала нет (нет сессионной шины, нет
xdg-desktop-portal или FileChooser в нём, `FMXWAYLAND_PORTAL=0`), сразу открывается собственный диалог файлов на FMX
(`FMXWayland.FileDialog`). Свой бэкенд ставится через `SetWaylandDialogBackend`. Всё это прислал
[Hemul GM](https://github.com/HemulGM), спасибо! Проверено на headless Weston (без шины), sway, KWin и GNOME Shell
(свой диалог FMX с вводом и диалоги портала: xdg-desktop-portal-gtk, -kde; в GNOME — тоже -gtk, потому что
xdg-desktop-portal-gnome отдаёт диалоги Nautilus, а тот не запускается от root).

**Требования:** Delphi 13 с платформой Linux, Linux SDK (`tools\make-linux-sdk.ps1 -CreateDistro -Install` делает его из дистрибутива WSL Ubuntu 22.04: программам нужна
glibc 2.35 или новее);
в системе libwayland-client, libxkbcommon и для стандартного канваса cairo, Pango, pangocairo, gdk-pixbuf (есть на
любом десктопе); для диалогов рабочего стола — xdg-desktop-portal с бэкендом (без него — диалог FMX).

**Сборка:** `.\tools\build.ps1 -Project samples\Hello\Hello.dpr` (Skia; с `-Define NOSKIA` — стандартный канвас,
без `libsk4d.so`). Сравнение двух канвасов: `tests\canvas-check.ps1`. **Запуск в WSLg:**
`XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir WAYLAND_DISPLAY=wayland-0 ./Hello` (без `DISPLAY`).

**FastCanvas (Vulkan):** [FastCanvas](https://github.com/Fasday/FMXFastCanvas) работает на FMXWayland нативно:
окна верхнего уровня (формы, модальные формы, диалоги, `TForm3D`) презентуются в свои `wl_surface` через
`VK_KHR_wayland_surface` из потока FastCanvas (режим `MAILBOX`, иначе `IMMEDIATE`, не `FIFO`), всплывающие окна и
прозрачные формы FastCanvas рисует на GPU, считывает и отдаёт в кадр FMXWayland через `FmuxCanvasDrawBitmap`. Без
GTK, X11, Skia и libfmux; проекты не зависят друг от друга при компиляции. Платформенный сервис
`IFMXWaylandNativeWindow` (`{B04A2FBC-1322-42BC-98A6-D526A7854F2C}`) отдаёт `wl_display`, `wl_surface` окна, размер
буфера и масштаб; `SetExternalPresentation` отключает наши wl_shm-кадры. Под внешней презентацией у окна есть
`wp_viewport` (буфер любого размера валиден), состояние окна для нового размера (viewport, геометрия, декорации)
отправляется рядом с подтверждением configure и перед каждой отрисовкой, окно считается отображённым после первой
отрисовки; перед скрытием окна FastCanvas прекращает презентацию. Сборка Hello с FastCanvas:
`.\tools\build.ps1 -Project samples\Hello\Hello.dpr -Define FASTCANVAS -SearchPath
<FastCanvas>\src\Canvas,<FastCanvas>\third_party\pasvulkan\src`.
Проверки: `tests\weston-headless.ps1 -Canvas TFastCanvas`, `tests\compositors.ps1 -Canvas TFastCanvas`. Подробности,
контракт и результаты — в README.md (разделы «FastCanvas (Vulkan)» и «IFMXWaylandNativeWindow»).

**Свой заголовок окна (FMR Ribbon и др.):** сервис `IFMXWaylandWindowFrame` (`{547B5786-5639-43A4-A598-1A03B465783A}`,
объявление из FMR Ribbon, модуль `FMXWayland.Frame`): `SetDecorated(False)` убирает все декорации окна (и наши, и
композитора через xdg-decoration `client_side`), `BeginMove`/`BeginResize`/`ShowWindowMenu` запускают перемещение,
изменение размера и оконное меню композитора с serial последнего нажатия (перемещение начинается, когда указатель
сдвинут на 4 пикселя, как в GTK), `Minimize`, `SetMaximized`, состояния и возможности оконного менеджера, слушатель
изменений. Пример: `Hello --own-titlebar`; проверено на Weston, sway, KWin и GNOME Shell (таблица в README.md).

**Шрифт по умолчанию:** `IFMXSystemFontService` даёт FMX шрифт рабочего стола вместо «Tahoma», которого в Linux
нет: в GNOME — `font-name` из `org.gnome.desktop.interface`, прочитанный через портал настроек
(`org.freedesktop.portal.Settings`; семейство, как его разрешает fontconfig, размер из пунктов в пиксели FMX:
11 pt = 14,7), иначе семейство `sans-serif` из fontconfig и размер 12 (как у FMX);
`FMXWAYLAND_FONT="семейство[,размер]"` меняет его. Всплывающие окна, открытые до того, как окно-родитель показано,
ждут его (xdg-shell требует отображённого родителя).

**Не работает пока:** главное меню (`TMainMenu`), drag and drop, картинки в буфере обмена, IME, тач, печать,
веб-браузер, медиа; позиционирование окон (ограничение Wayland). Множественный выбор через `TOpenDialog` ограничен
буфером FMX в 1024 символа. Подробный статус всех функций FMUX —
в [docs/FMUX-STATUS.md](docs/FMUX-STATUS.md), планы — в README.md («Next steps»).

**Ошибка FMX:** форма, освобождённая из кода при открытом выпадающем списке `TComboBox`/`TComboEdit`, падает в
`TCustomForm.DoRemoveObject` (на Windows та же программа зависает при выходе — это ошибка FMX, не FMXWayland). выпадающие списки формы перед её освобождением: пример `CloseDropDowns` — в README.md (`What does not yet`), в FMR Ribbon — `FmrCloseDropDowns`.

Лицензия MIT.
