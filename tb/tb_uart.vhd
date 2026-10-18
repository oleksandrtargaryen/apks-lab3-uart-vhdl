--------------------------------------------------------------------------------
-- Файл        : tb_uart.vhd
-- Проєкт      : Лабораторна робота №3 — UART на VHDL (варіант 1)
-- Автор       : Бартошко Олександр Ігорович, група КІ-408
--
-- Призначення : Самоперевірний (self-checking) тестбенч для uart_top.
--               Імітує зовнішнє середовище модуля:
--                 * генерує системний такт CLK = 50 МГц та сигнал RESET;
--                 * подає тестові байти на вхід передавача (Tx);
--                 * декодує послідовний потік TXD незалежним «програмним»
--                   приймачем тестбенча і перевіряє старт/дані/стоп та
--                   точність часових меж кожного біта;
--                 * імітує зовнішній пристрій, що передає байти на RXD
--                   (зокрема з розбіжністю швидкості ±3 %, із завадою та з
--                   помилкою стоп-біта), і перевіряє rx_data/rx_valid;
--                 * виконує петльовий тест (loopback) TXD -> RXD.
--               Будь-яка невідповідність -> assert ... severity failure.
--               Після успішного проходження друкується "TEST PASSED".
--
-- Примітка    : повідомлення report — латиницею (GHDL не підтримує
--               UTF-8 у рядкових літералах), коментарі — українською.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_uart is
    generic (
        G_CLK_FREQ : positive := 50_000_000;   -- системний такт, Гц
        G_BAUD     : positive := 115_200       -- швидкість UART, бод
    );
end entity tb_uart;

architecture sim of tb_uart is

    ----------------------------------------------------------------------------
    -- Часові константи (обчислюються так само, як у baud_gen)
    ----------------------------------------------------------------------------
    constant OVERSAMPLE : positive := 16;
    constant T_CLK      : time     := 1 sec / G_CLK_FREQ;          -- 20 нс
    constant DIVISOR    : positive :=
        (G_CLK_FREQ + (G_BAUD * OVERSAMPLE) / 2) / (G_BAUD * OVERSAMPLE);
    constant T_BIT      : time     := T_CLK * (DIVISOR * OVERSAMPLE); -- 8.64 мкс
    constant T_FRAME    : time     := 10 * T_BIT;                  -- 1 кадр 8N1
    constant T_TOL      : time     := T_CLK;                       -- допуск часу

    type byte_array_t is array (natural range <>) of std_logic_vector(7 downto 0);

    -- Тестові набори
    constant TX_VECTORS : byte_array_t := (x"55", x"A3", x"00", x"FF");
    constant RX_VECTORS : byte_array_t := (x"3C", x"C5", x"81");

    ----------------------------------------------------------------------------
    -- Сигнали, що підключаються до DUT
    ----------------------------------------------------------------------------
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal tx_start     : std_logic := '0';
    signal tx_data      : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_busy      : std_logic;
    signal tx_done      : std_logic;
    signal rx_data      : std_logic_vector(7 downto 0);
    signal rx_valid     : std_logic;
    signal rx_frame_err : std_logic;
    signal uart_txd     : std_logic;
    signal uart_rxd     : std_logic;

    -- Модель зовнішнього пристрою та керування петлею
    signal ext_rxd   : std_logic := '1';     -- лінія від «зовнішнього» передавача
    signal loopback  : boolean   := false;   -- true: RXD <= TXD
    signal sim_done  : boolean   := false;   -- зупинка генератора такту

    -- Результати TB-декодера лінії TXD
    signal mon_byte    : std_logic_vector(7 downto 0) := (others => '0');
    signal mon_count   : natural := 0;       -- кількість декодованих кадрів
    signal mon_start_t : time    := 0 ns;    -- момент спаду старт-біта

    -- Результати спостереження за виходами приймача
    signal rx_count : natural := 0;          -- кількість імпульсів rx_valid
    signal fe_count : natural := 0;          -- кількість імпульсів rx_frame_err
    signal rx_last  : std_logic_vector(7 downto 0) := (others => '0');

    function hex(v : std_logic_vector) return string is
    begin
        return "0x" & to_hstring(v);
    end function;

begin

    ----------------------------------------------------------------------------
    -- Пристрій, що тестується (DUT)
    ----------------------------------------------------------------------------
    dut : entity work.uart_top
        generic map (
            CLK_FREQ   => G_CLK_FREQ,
            BAUD       => G_BAUD,
            OVERSAMPLE => OVERSAMPLE
        )
        port map (
            clk          => clk,
            rst          => rst,
            tx_start     => tx_start,
            tx_data      => tx_data,
            tx_busy      => tx_busy,
            tx_done      => tx_done,
            rx_data      => rx_data,
            rx_valid     => rx_valid,
            rx_frame_err => rx_frame_err,
            uart_txd     => uart_txd,
            uart_rxd     => uart_rxd
        );

    -- Генератор такту 50 МГц (зупиняється після завершення тесту)
    clk <= not clk after T_CLK / 2 when not sim_done;

    -- Вхід приймача: або зовнішній пристрій, або власний TXD (петля)
    uart_rxd <= uart_txd when loopback else ext_rxd;

    ----------------------------------------------------------------------------
    -- TB-декодер лінії TXD (незалежна поведінкова модель приймача).
    -- Ловить спад старт-біта, далі вибирає кожен біт у його середині та
    -- перевіряє, що будь-яка зміна лінії сталася точно на межі бітів
    -- (t0 + k*T_BIT), тобто тривалість кожного біта = T_BIT.
    ----------------------------------------------------------------------------
    p_tx_monitor : process
        variable t0  : time;
        variable b   : std_logic_vector(7 downto 0);
        variable le  : time;

        -- Перевірка часу останньої зміни лінії в середині біта:
        -- або лінія змінилась рівно на межі цього біта (last_event = T/2),
        -- або не змінювалась щонайменше від середини попереднього біта.
        procedure check_edge_timing(name : string) is
        begin
            le := uart_txd'last_event;
            assert (le >= T_BIT / 2 - T_TOL and le <= T_BIT / 2 + T_TOL)
                or (le >= T_BIT + T_BIT / 2 - T_TOL)
                report "TX monitor: wrong edge timing in " & name &
                       ", last_event = " & to_string(le, 1 ns)
                severity failure;
        end procedure;
    begin
        wait until falling_edge(uart_txd);
        t0 := now;

        -- Старт-біт: середина, має бути '0'
        wait for T_BIT / 2;
        check_edge_timing("START");
        assert uart_txd = '0'
            report "TX monitor: start bit is not '0' at mid-bit" severity failure;

        -- 8 біт даних, LSB first
        for i in 0 to 7 loop
            wait for T_BIT;
            check_edge_timing("D" & integer'image(i));
            b(i) := uart_txd;
        end loop;

        -- Стоп-біт: середина, має бути '1'
        wait for T_BIT;
        check_edge_timing("STOP");
        assert uart_txd = '1'
            report "TX monitor: stop bit is not '1' (framing)" severity failure;

        mon_byte    <= b;
        mon_start_t <= t0;
        mon_count   <= mon_count + 1;
    end process p_tx_monitor;

    ----------------------------------------------------------------------------
    -- Спостерігач виходів приймача: підрахунок rx_valid / rx_frame_err
    ----------------------------------------------------------------------------
    p_rx_monitor : process (clk)
    begin
        if rising_edge(clk) then
            if rx_valid = '1' then
                rx_last  <= rx_data;
                rx_count <= rx_count + 1;
            end if;
            if rx_frame_err = '1' then
                fe_count <= fe_count + 1;
            end if;
        end if;
    end process p_rx_monitor;

    ----------------------------------------------------------------------------
    -- Сторожовий таймер: аварійне завершення при «зависанні»
    ----------------------------------------------------------------------------
    p_watchdog : process
    begin
        wait for 200 * T_FRAME;
        assert sim_done report "WATCHDOG: simulation timeout" severity failure;
        wait;
    end process p_watchdog;

    ----------------------------------------------------------------------------
    -- Основний сценарій тесту
    ----------------------------------------------------------------------------
    p_stimulus : process

        -- Запит на передачу байта передавачем DUT (імпульс tx_start, 1 такт)
        procedure dut_send(b : std_logic_vector(7 downto 0)) is
        begin
            wait until rising_edge(clk);
            tx_data  <= b;
            tx_start <= '1';
            wait until rising_edge(clk);
            tx_start <= '0';
        end procedure;

        -- Модель зовнішнього UART-передавача (поведінкова, асинхронна до clk):
        -- старт '0', 8 біт LSB first, стоп-біт stop_val, потім лінія '1'.
        procedure ext_send(b        : std_logic_vector(7 downto 0);
                           bit_t    : time;
                           stop_val : std_logic := '1') is
        begin
            ext_rxd <= '0';
            wait for bit_t;
            for i in 0 to 7 loop
                ext_rxd <= b(i);
                wait for bit_t;
            end loop;
            ext_rxd <= stop_val;
            wait for bit_t;
            ext_rxd <= '1';
        end procedure;

        -- Перевірка, що приймач видав очікуваний байт
        procedure check_rx(exp : std_logic_vector(7 downto 0);
                           n   : natural;
                           tag : string) is
        begin
            if rx_count /= n then
                wait until rx_count = n for 2 * T_BIT;
            end if;
            assert rx_count = n
                report tag & ": rx_valid not asserted (rx_count=" &
                       integer'image(rx_count) & ", expected " &
                       integer'image(n) & ")"
                severity failure;
            assert rx_last = exp
                report tag & ": RX mismatch, expected " & hex(exp) &
                       ", got " & hex(rx_last)
                severity failure;
            report tag & ": received " & hex(rx_last) & " - OK";
        end procedure;

        variable n_tx   : natural := 0;   -- очікувана кількість кадрів на TXD
        variable n_rx   : natural := 0;   -- очікувана кількість rx_valid
        variable t_done : time;

    begin
        report "UART TB: CLK_FREQ=" & integer'image(G_CLK_FREQ) &
               " Hz, BAUD=" & integer'image(G_BAUD) &
               ", DIVISOR=" & integer'image(DIVISOR) &
               ", T_BIT=" & to_string(T_BIT, 1 ns) &
               ", real baud=" & integer'image(G_CLK_FREQ / (DIVISOR * OVERSAMPLE));

        ------------------------------------------------------------------------
        -- 0. Скидання
        ------------------------------------------------------------------------
        rst <= '1';
        for i in 1 to 10 loop
            wait until rising_edge(clk);
        end loop;
        rst <= '0';
        wait until rising_edge(clk);
        assert uart_txd = '1' and tx_busy = '0'
            report "RESET: TXD must be '1' (idle) and tx_busy '0'" severity failure;
        report "RESET: OK (TXD idle = 1, tx_busy = 0)";

        ------------------------------------------------------------------------
        -- 1. Перевірка передавача: байти 0x55, 0xA3, 0x00, 0xFF «впритул»
        ------------------------------------------------------------------------
        report "=== PHASE 1: transmitter test ===";
        for k in TX_VECTORS'range loop
            dut_send(TX_VECTORS(k));
            n_tx := n_tx + 1;
            wait for T_CLK / 4;   -- tx_busy оновлюється після фронту clk
            assert tx_busy = '1'
                report "TX: tx_busy not asserted after tx_start" severity failure;

            -- Під час передачі 0xA3 подаємо «чужий» запит 0x99 —
            -- він має ігноруватися, бо передавач зайнятий.
            if TX_VECTORS(k) = x"A3" then
                wait for 3 * T_BIT;
                dut_send(x"99");
            end if;

            wait until tx_done = '1' for 2 * T_FRAME;
            assert tx_done = '1' report "TX: tx_done timeout" severity failure;
            t_done := now;
            wait for 0 ns;   -- дельта-цикл: оновлення сигналів монітора
            assert mon_count = n_tx
                report "TX: monitor did not decode a frame" severity failure;
            assert mon_byte = TX_VECTORS(k)
                report "TX: decoded " & hex(mon_byte) & ", expected " &
                       hex(TX_VECTORS(k))
                severity failure;
            -- Тривалість кадру: від спаду старт-біта до tx_done = 10 біт
            assert abs ((t_done - mon_start_t) - T_FRAME) <= T_TOL
                report "TX: frame duration " & to_string(t_done - mon_start_t, 1 ns) &
                       " /= " & to_string(T_FRAME, 1 ns)
                severity failure;
            report "TX: sent " & hex(TX_VECTORS(k)) & ", TB decoder got " &
                   hex(mon_byte) & ", frame " &
                   to_string(t_done - mon_start_t, 1 ns) & " - OK";
            wait until rising_edge(clk);
        end loop;

        -- Пересвідчуємось, що зайвий запит 0x99 не породив кадр
        wait for 2 * T_FRAME;
        assert mon_count = n_tx
            report "TX: unexpected extra frame (request while busy not ignored)"
            severity failure;
        assert rx_count = 0
            report "RX: unexpected data while RXD idle" severity failure;
        report "TX: request during busy ignored - OK";

        ------------------------------------------------------------------------
        -- 2. Перевірка приймача: зовнішній пристрій надсилає байти
        ------------------------------------------------------------------------
        report "=== PHASE 2: receiver test (external device) ===";
        wait for 7 ns;   -- зсув фази: зовнішні фронти не збігаються з clk

        -- 2a. Номінальна швидкість, кадри впритул: 0x3C, 0xC5, 0x81
        for k in RX_VECTORS'range loop
            ext_send(RX_VECTORS(k), T_BIT);
            n_rx := n_rx + 1;
            check_rx(RX_VECTORS(k), n_rx, "RX nominal");
        end loop;
        wait for 2 * T_BIT;

        -- 2b. Розбіжність швидкостей ±3 %
        ext_send(x"5A", T_BIT * 103 / 100);
        n_rx := n_rx + 1;
        check_rx(x"5A", n_rx, "RX baud -3%");
        wait for 2 * T_BIT;
        ext_send(x"A5", T_BIT * 97 / 100);
        n_rx := n_rx + 1;
        check_rx(x"A5", n_rx, "RX baud +3%");
        wait for 2 * T_BIT;

        -- 2c. Короткий імпульс-завада (1/4 біта) — не повинен сприйматися
        --     як старт-біт (перевірка старт-біта в його середині)
        ext_rxd <= '0';
        wait for T_BIT / 4;
        ext_rxd <= '1';
        wait for 2 * T_BIT;
        assert rx_count = n_rx and fe_count = 0
            report "RX: glitch was accepted as a start bit" severity failure;
        report "RX glitch (T_BIT/4): rejected - OK";

        -- 2d. Помилка кадру: стоп-біт = '0' -> rx_frame_err, без rx_valid
        ext_send(x"7E", T_BIT, '0');
        wait for T_BIT;
        assert fe_count = 1
            report "RX: frame error not detected" severity failure;
        assert rx_count = n_rx
            report "RX: rx_valid asserted for a broken frame" severity failure;
        report "RX framing error (stop=0): rx_frame_err detected - OK";
        wait for 2 * T_BIT;

        -- 2e. Відновлення після помилки кадру
        ext_send(x"42", T_BIT);
        n_rx := n_rx + 1;
        check_rx(x"42", n_rx, "RX after frame error");
        wait for 2 * T_BIT;

        ------------------------------------------------------------------------
        -- 3. Петльовий тест: TXD -> RXD, передача і прийом одночасно
        ------------------------------------------------------------------------
        report "=== PHASE 3: loopback test (TXD -> RXD) ===";
        loopback <= true;
        wait for T_BIT;
        for k in TX_VECTORS'range loop
            dut_send(TX_VECTORS(k));
            n_tx := n_tx + 1;
            n_rx := n_rx + 1;
            wait until rx_count = n_rx for 2 * T_FRAME;
            check_rx(TX_VECTORS(k), n_rx, "LOOPBACK");
            if tx_busy = '1' then
                wait until tx_busy = '0';
            end if;
        end loop;
        wait for T_BIT;
        assert mon_count = n_tx
            report "LOOPBACK: TX monitor frame count mismatch" severity failure;
        assert fe_count = 1
            report "LOOPBACK: unexpected framing errors" severity failure;

        ------------------------------------------------------------------------
        -- Підсумок
        ------------------------------------------------------------------------
        report "SUMMARY: TX frames checked = " & integer'image(mon_count) &
               ", RX bytes checked = " & integer'image(rx_count) &
               ", framing errors detected = " & integer'image(fe_count) &
               " (expected 1)";
        report "TEST PASSED";
        sim_done <= true;
        wait for 10 * T_CLK;
        std.env.finish;   -- коректне завершення симуляції
        wait;
    end process p_stimulus;

end architecture sim;
