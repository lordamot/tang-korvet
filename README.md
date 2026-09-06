# Korvet Nano

**ПК8020 «Корвет»** - советский школьный компьютер 1987 года на
КР580ВМ80А, с текстовым слоем над тремя графическими и палитрой - на
**Tang Nano 20K** с платой **BL616** (M0S Dock) рядом.  Сделано по образцу
и на основе [PK8000 Nano](https://github.com/lordamot/tang-pk8000) и через
него [UKNC Nano](https://github.com/lordamot/tang-uknc) (аппаратная часть
- Алексей Гуров, линия 2.x - Сергей Лемешев и Claude Code): оттуда взяты
связь с BL616, HDMI-кодер со звуком, расписание SDRAM, инструменты и
метод.  Процессор - vm80a (1801BM1/Vslav, CC-BY 3.0), точная копия
кристалла 580ВМ80А, или tv80 (Guy Hutchison, MIT) как Z80-ускоритель.
Версия - в файле `VERSION`, история - в `CHANGELOG.md`, лицензия - MIT
(`LICENCE.md`).  *English below.*

**Состояние (5 сентября 2026): собирается, проходит временной анализ,
в симуляции ОПТС проходит тесты памяти.  На плате ещё не запускалось.**

## Что умеет

- КР580ВМ80А на 2,5 МГц с тактом ожидания при обращении к устройствам,
  как на плате; или Z80-ускоритель на 2,5 или 5 МГц (выбор в меню).
- Карта памяти - уравнения ПЛМ D31 (32 конфигурации системного
  регистра 7Fh), 64 КБ ОЗУ, ГЗУ 192 КБ (четыре страницы) или 48 КБ (одна),
  АЦЗУ с битом атрибута.
- ОПТС 2.0 встроена; любой другой образ ПЗУ (ОПТС 1.1 и т. п.) - файлом с
  карты через меню.
- Экран 512×256, оба знакогенератора, 32 и 64 символа, палитра; по HDMI
  как 1024×512 при 49,5 Гц.
- ВИ53, ВН59, три ВВ55, две ВВ51, ВГ93 с четырьмя дисководами из образов
  `.kdi` на карте.
- Клавиатура USB, переведённая в две матрицы Корвета; мышь USB как
  последовательная Microsoft на ВВ51 (Абрис, Спред).
- Пьезоизлучатель, двухбитный «ковокс» кассетного выхода и модуль AY на
  боковом разъёме - по HDMI и I²S.
- **Korvet-EXTROM** - эмулятор дисководов forth32 на боковом разъёме:
  сторона разъёма в ПЛИС, программа контроллера в BL616, карта -
  папка `extrom` на SD-карте (образы в `extrom/DISK`, монтирование
  командой MOUNT из CP/M, загрузка ПК8010 без контроллера дисковода).
- Меню по **F12**: четыре дисковода, процессор, образ ОПТС, контроллер
  НГМД, ExtROM, AY, мышь, размер ГЗУ, громкость, пищалка, защита записи,
  «About», «Debug», сохранение настроек на карту.
- В `soft/`: диск с играми и диск диагностики КТДП.

Чего пока нет: магнитофона файлами, принтера, сети, джойстика.
Состояние и порядок - в `.claude/docs/progress.md`.

## Что нужно

- Tang Nano 20K, плата BL616 (M0S Dock), SD-карта FAT32, USB-клавиатура,
  USB-мышь по желанию.
- Семь проводов между платами - распиновка **как в исходном MiSTeryNano**,
  в UKNC Nano и PK8000 Nano:

```
Tang Nano 20K   BL616
42              io10   MISO
41              io11   MOSI
56              io12   CSN
54              io13   SCK
51              io14   IRQ
GND             GND
+5              +5
```

Звук I²S - на выводах 71 (BCK), 72 (WS), 73 (DIN), 74 (разрешение
усилителя); по HDMI звук идёт сам.

## Карта

- `/korvet.ini` - настройки («Save settings»).
- Образы `.kdi` - где угодно; дисководы A-D выбираются в меню.
- Образ ПЗУ (`.rom`, `.bin`, до 32 КБ) - где угодно; «OPTS ROM» в меню.
- `/extrom/` - карта ExtROM: `STAGE1.ROM`, `STAGE2.ROM`, `SYSTEM.BIN`,
  `MICRODOS.BIN`, `EXRTOOLS.KDI`, `ROM0.BIN`..`ROM7.BIN`, папка `DISK/` с
  `DISKA.KDI`..`DISKD.KDI` (имена 8.3, папки одного уровня) - ровно то,
  что лежит на карте настоящего контроллера.  `.claude/docs/extrom.md`.

## Как прошить

**BL616** - через его загрузчик: удерживая **BOOT**, подключить USB (или
нажать **RST**), отпустить BOOT; плата появится как последовательный
порт.  Дальше либо BLDevCube (чип BL616/BL618, вкладка MCU, файл
`bin/bl616.bin`, адрес `0x00000000`, скорость 2000000, Create & Download),
либо из этого репозитория:

```sh
make flash-mcu COMX=/dev/ttyACM0
```

После прошивки нажать RST.

**Tang Nano 20K** - через openFPGALoader (или Gowin Programmer):

```sh
openFPGALoader -b tangnano20k -f bin/tang.fs     # во флеш
make flash-fpga-flash                            # то же из репозитория
```

и **выключить-включить питание**: после записи во флеш плата продолжает
работать со старой прошивкой, пока её не перезапустить.

## Как пользоваться

Включить - ОПТС покажет синий экран и секунд девять будет проверять
память, потом загрузится с диска A, с ExtROM (если включён) или запустит
Бейсик.  **F12** открывает меню; курсор - по пунктам, влево/вправо -
значение, пробел или Enter - выбрать, ESC - закрыть.  Раскладка:
буквы и цифры - как на клавише; `=` даёт `^`, `'` даёт `:`, `` ` `` - `@`,
F6 - `_`, F7 и Pause - СТОП, F8 и Caps Lock - ФИКС, F9 - СЕЛ, F10 и левый
Alt - ГРФ, F11 и правый Alt - АЛФ, Esc - ПРФ, стрелки и цифровая
клавиатура - клавиши второго поля; подробно - `howto.md`.

## Как собрать

```sh
make toolchain    # один раз, ~7 ГБ в tools/
make lint         # Verilator, секунды
make sim          # машина целиком, до синего экрана ОПТС (минуты)
make frames       # то же, кадры экрана в sim/out/*.ppm
make bitstream    # прошивка ПЛИС -> bin/tang.fs, с проверкой временных ограничений
make fw           # прошивка BL616 -> build/fw/bl616.bin
```

---

# Korvet Nano

The **ПК8020 "Корвет"**, the Soviet school computer of 1987 - a
КР580ВМ80А (8080A) with a text plane over three graphics planes and a
colour table - on a **Tang Nano 20K** with a **BL616** board (M0S Dock)
beside it.  Modelled on and built from
[PK8000 Nano](https://github.com/lordamot/tang-pk8000) and through it
[UKNC Nano](https://github.com/lordamot/tang-uknc) (hardware by Alexey
Gurov; the 2.x line by Sergei Lemeshev and Claude Code): the BL616 link,
the HDMI encoder with audio, the SDRAM timetable, the tools and the
method are taken from there.  The CPU is vm80a (1801BM1/Vslav, CC-BY
3.0), a gate-level replica of the 580ВМ80А die, or tv80 (Guy Hutchison,
MIT) as the Z80 accelerator.  The version is in `VERSION`, the history
in `CHANGELOG.md`, the licence is MIT (`LICENCE.md`).

**State (5 September 2026): builds, meets timing, the ОПТС passes its
memory tests in simulation.  Not yet run on a board.**

## Features

- The КР580ВМ80А at 2.5 MHz with the board's wait state on device
  access; or the Z80 accelerator at 2.5 or 5 MHz (a menu choice).
- The memory map as the PLM D31's equations (32 configurations of the
  system register 7Fh), 64 KB RAM, 192 KB (four pages) or 48 KB (one)
  of graphics RAM, the text RAM with its attribute bit.
- ОПТС 2.0 built in; any other ROM image (ОПТС 1.1, ...) as a file from
  the card through the menu.
- The 512x256 display, both fonts, 32 and 64 columns, the colour table;
  over HDMI as 1024x512 at 49.5 Hz.
- ВИ53, ВН59, three ВВ55, two ВВ51, the ВГ93 with four drives from
  `.kdi` images on the card.
- A USB keyboard translated into the Корвет's two matrices; a USB mouse
  as a Microsoft serial mouse on the ВВ51 (Abris, Spred).
- The piezo, the tape output's two-bit DAC and the AY module on the side
  connector, over HDMI and I²S.
- **Korvet-EXTROM** - forth32's floppy emulator on the side connector:
  the connector side in the FPGA, the controller's program in the BL616,
  its card the SD card's `extrom` folder (images in `extrom/DISK`,
  mounting with MOUNT from CP/M, booting a ПК8010 with no floppy
  controller).
- A menu on **F12**: four drives, the CPU, the ROM image, the floppy
  controller, ExtROM, AY, mouse, graphics RAM size, volume, beeper,
  write protection, About, Debug, settings saved to the card.
- In `soft/`: a games disk and the КТДП diagnostics disk.

Not yet: tape as files, the printer, the network, a joystick.
`.claude/docs/progress.md` has the state.

## What you need

- A Tang Nano 20K, a BL616 board (M0S Dock), a FAT32 SD card, a USB
  keyboard, a USB mouse if wanted.
- Seven wires between the boards - the **stock MiSTeryNano pinout**, as
  UKNC Nano and PK8000 Nano wire it (table above).  I²S audio on pins 71
  (BCK), 72 (WS), 73 (DIN), 74 (amplifier enable); HDMI carries the
  sound itself.

## The card

- `/korvet.ini` - the settings ("Save settings").
- `.kdi` images anywhere; drives A-D are chosen in the menu.
- A ROM image (`.rom`, `.bin`, up to 32 KB) anywhere; "OPTS ROM" in the menu.
- `/extrom/` - the ExtROM's card: `STAGE1.ROM`, `STAGE2.ROM`,
  `SYSTEM.BIN`, `MICRODOS.BIN`, `EXRTOOLS.KDI`, `ROM0.BIN`..`ROM7.BIN`, a
  `DISK/` folder with `DISKA.KDI`..`DISKD.KDI` (8.3 names, one level of
  folders) - exactly what the real controller's card holds.
  `.claude/docs/extrom.md`.

## How to flash

**BL616**, through its bootloader: hold **BOOT**, plug in USB (or press
**RST**), release BOOT; the board shows up as a serial port.  Then either
BLDevCube (chip BL616/BL618, MCU tab, file `bin/bl616.bin`, address
`0x00000000`, baud 2000000, Create & Download) or, from this repository:

```sh
make flash-mcu COMX=/dev/ttyACM0
```

Press RST afterwards.

**Tang Nano 20K**, with openFPGALoader (or the Gowin Programmer):

```sh
openFPGALoader -b tangnano20k -f bin/tang.fs     # to flash
make flash-fpga-flash                            # the same from the repository
```

then **power-cycle the board**: after a write to flash it keeps running
the old bitstream until it is restarted.

## How to use it

Power on; the ОПТС shows its blue screen and tests the memory for about
nine seconds, then boots from the ExtROM if it is on, else from drive
A, else starts its BASIC.  **F12** opens the menu; cursor keys move, left and right
step a value, Space or Enter selects, ESC closes.  Keys are by
position: `=` is `^`, `'` is `:`, `` ` `` is `@`, F6 `_`, F7 and Pause
СТОП, F8 and Caps Lock ФИКС, F9 СЕЛ, F10 and left Alt ГРФ, F11 and right
Alt АЛФ, Esc ПРФ, the cursor keys and the keypad the second field's
keys; the whole table is in `howto.md`.

## How to build

```sh
make toolchain    # once, ~7 GB into tools/
make lint         # Verilator, seconds
make sim          # the whole machine, to the ОПТС's blue screen (minutes)
make frames       # the same, with the screen as sim/out/*.ppm
make bitstream    # the FPGA bitstream -> bin/tang.fs, through the timing gate
make fw           # the BL616 firmware -> build/fw/bl616.bin
```
