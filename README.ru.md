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
буфер обмена (текст), таймеры, `TThread.Synchronize`, модальные формы, окна сообщений, развернуть/восстановить,
закрытие композитором, целочисленный HiDPI-масштаб, собственные декорации окна (заголовок с кнопками, перемещение,
изменение размера), если композитор не рисует их сам (WSLg, Weston, GNOME). Проверено на WSLg (тест с настоящим
вводом с Windows: `tests\hello-e2e.ps1`) и на headless Weston 14 с масштабом 1 и 2 (`tests\weston-headless.ps1`).

**Канвасы.** Стандартный канвас FMX (`FMX.Canvas.Linux`) работает через функции канваса, текста и кодеков FMUX,
реализованные в `FMXWayland.Cairo` на системных cairo, Pango и gdk-pixbuf (их прислал [Hemul GM](https://github.com/HemulGM), спасибо!); FMX
перерисовывает только изменённую область сохранённого кадра окна. Skia — по желанию: `FMX.Skia` и
`GlobalUseSkia := True` в программе, `libsk4d.so` рядом с ней.

**Требования:** Delphi 13 с платформой Linux, Linux SDK (`tools\make-linux-sdk.ps1` делает его из дистрибутива WSL);
в системе libwayland-client, libxkbcommon и для стандартного канваса cairo, Pango, pangocairo, gdk-pixbuf (есть на
любом десктопе).

**Сборка:** `.\tools\build.ps1 -Project samples\Hello\Hello.dpr` (Skia; с `-Define NOSKIA` — стандартный канвас,
без `libsk4d.so`). Сравнение двух канвасов: `tests\canvas-check.ps1`. **Запуск в WSLg:**
`XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir WAYLAND_DISPLAY=wayland-0 ./Hello` (без `DISPLAY`).

**Для FastCanvas (Vulkan):** платформенный сервис `IFMXWaylandNativeWindow`
(`{B04A2FBC-1322-42BC-98A6-D526A7854F2C}`) отдаёт `wl_display`, `wl_surface` окна, размер буфера и масштаб;
`SetExternalPresentation` отключает наши wl_shm-кадры, когда окно презентует Vulkan. Контракт описан в README.md.

**Не работает пока:** главное меню (`TMainMenu`), drag and drop, диалоги файлов, картинки в буфере обмена, IME,
тач, печать, веб-браузер, медиа; позиционирование окон (ограничение Wayland). Подробный статус всех функций FMUX —
в [docs/FMUX-STATUS.md](docs/FMUX-STATUS.md), планы — в README.md («Next steps»).

Лицензия MIT.
