--------------------------------------------------------------------------------
-- Файл        : uart_tx.vhd
-- Проєкт      : Лабораторна робота №3 — UART на VHDL (варіант 1)
-- Автор       : Бартошко Олександр Ігорович, група КІ-408
--
-- Призначення : Передавач UART, формат кадру 8N1:
--                 1 старт-біт ('0') + 8 біт даних (молодший біт першим, LSB
--                 first) + 1 стоп-біт ('1'), без біта парності.
--               У стані спокою лінія TXD утримується в '1' (mark).
--
-- Тактування  : вхід `tick` — імпульси дозволу з частотою BAUD*OVERSAMPLE
--               від baud_gen. Тривалість кожного біта = OVERSAMPLE імпульсів
--               tick (для x16 і 50 МГц: 16 * 27 = 432 такти clk = 8.64 мкс).
--               Початок старт-біта вирівнюється по імпульсу tick, тому всі
--               10 бітів кадру мають однакову, точну тривалість.
--
-- Автомат (FSM):
--   IDLE  : лінія = '1'. Запит tx_start фіксує байт у зсувному регістрі,
--           виставляє tx_busy; на найближчому tick -> START.
--   START : лінія = '0' протягом 1 біта (OVERSAMPLE tick)      -> DATA
--   DATA  : видаються 8 біт, LSB first; після 8-го біта        -> STOP
--   STOP  : лінія = '1' протягом 1 біта; імпульс tx_done      -> IDLE
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
    generic (
        OVERSAMPLE : positive := 16            -- імпульсів tick на один біт
    );
    port (
        clk       : in  std_logic;                     -- системний такт
        rst       : in  std_logic;                     -- синхронне скидання ('1')
        tick      : in  std_logic;                     -- дозвіл від baud_gen
        tx_start  : in  std_logic;                     -- запит на передачу (1 такт);
                                                       -- ігнорується, поки tx_busy='1'
        tx_data   : in  std_logic_vector(7 downto 0);  -- байт для передачі
        tx_busy   : out std_logic;                     -- '1' — передавач зайнятий
        tx_done   : out std_logic;                     -- імпульс (1 такт) після стоп-біта
        txd       : out std_logic;                     -- послідовний вихід UART TXD
        state_dbg : out std_logic_vector(1 downto 0)   -- код стану FSM (для
                                                       -- осцилограм/налагодження):
                                                       -- 00 IDLE, 01 START,
                                                       -- 10 DATA, 11 STOP
    );
end entity uart_tx;

architecture rtl of uart_tx is

    -- Стани автомата передавача
    type tx_state_t is (IDLE, START, DATA, STOP);
    signal state : tx_state_t := IDLE;

    -- Лічильник імпульсів tick у межах поточного біта: 0 .. OVERSAMPLE-1
    signal tick_cnt : natural range 0 to OVERSAMPLE - 1 := 0;
    -- Номер біта даних, що передається: 0 .. 7
    signal bit_idx  : natural range 0 to 7 := 0;
    -- Зсувний регістр даних: на лінію видається молодший біт shreg(0)
    signal shreg    : std_logic_vector(7 downto 0) := (others => '0');
    -- Прапорець «запит прийнято, чекаємо tick для вирівнювання старт-біта»
    signal pending  : std_logic := '0';
    -- Вихідний регістр лінії (реєстровий вихід — без «глітчів» на TXD)
    signal txd_reg  : std_logic := '1';
    signal busy_reg : std_logic := '0';
    signal done_reg : std_logic := '0';

begin

    txd     <= txd_reg;
    tx_busy <= busy_reg;
    tx_done <= done_reg;

    -- Двобітний код стану для осцилограм (VCD не зберігає enum-типи наочно)
    with state select state_dbg <=
        "00" when IDLE,
        "01" when START,
        "10" when DATA,
        "11" when STOP;

    ----------------------------------------------------------------------------
    -- Основний процес автомата передавача (синхронний, один процес)
    ----------------------------------------------------------------------------
    p_fsm : process (clk)
    begin
        if rising_edge(clk) then
            done_reg <= '0';                       -- tx_done — імпульс 1 такт

            if rst = '1' then
                state    <= IDLE;
                tick_cnt <= 0;
                bit_idx  <= 0;
                shreg    <= (others => '0');
                pending  <= '0';
                txd_reg  <= '1';                   -- лінія у стані спокою
                busy_reg <= '0';
            else
                case state is

                    -- IDLE: очікування запиту. Байт фіксується одразу, а
                    -- старт-біт починається на найближчому імпульсі tick.
                    when IDLE =>
                        txd_reg <= '1';
                        if pending = '0' then
                            if tx_start = '1' then
                                shreg    <= tx_data;
                                pending  <= '1';
                                busy_reg <= '1';
                            end if;
                        elsif tick = '1' then
                            pending  <= '0';
                            txd_reg  <= '0';           -- початок старт-біта
                            tick_cnt <= 0;
                            state    <= START;
                        end if;

                    -- START: утримуємо '0' рівно OVERSAMPLE імпульсів tick
                    when START =>
                        if tick = '1' then
                            if tick_cnt = OVERSAMPLE - 1 then
                                tick_cnt <= 0;
                                bit_idx  <= 0;
                                txd_reg  <= shreg(0);  -- біт D0 (LSB first)
                                state    <= DATA;
                            else
                                tick_cnt <= tick_cnt + 1;
                            end if;
                        end if;

                    -- DATA: кожні OVERSAMPLE tick зсуваємо регістр вправо і
                    -- видаємо наступний біт; після D7 переходимо у STOP
                    when DATA =>
                        if tick = '1' then
                            if tick_cnt = OVERSAMPLE - 1 then
                                tick_cnt <= 0;
                                if bit_idx = 7 then
                                    txd_reg <= '1';    -- стоп-біт
                                    state   <= STOP;
                                else
                                    bit_idx <= bit_idx + 1;
                                    shreg   <= '0' & shreg(7 downto 1);
                                    txd_reg <= shreg(1);   -- наступний біт
                                end if;
                            else
                                tick_cnt <= tick_cnt + 1;
                            end if;
                        end if;

                    -- STOP: утримуємо '1' один біт, видаємо tx_done
                    when STOP =>
                        if tick = '1' then
                            if tick_cnt = OVERSAMPLE - 1 then
                                tick_cnt <= 0;
                                busy_reg <= '0';
                                done_reg <= '1';
                                state    <= IDLE;
                            else
                                tick_cnt <= tick_cnt + 1;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;
