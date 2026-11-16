--------------------------------------------------------------------------------
-- Файл        : uart_rx.vhd
-- Проєкт      : Лабораторна робота №3 — UART на VHDL (варіант 1)
-- Автор       : Бартошко Олександр Ігорович, група КІ-408
--
-- Призначення : Приймач UART, формат кадру 8N1 (1 старт, 8 даних LSB first,
--               1 стоп, без парності).
--
-- Логіка роботи приймача:
--   1. Синхронізація. Вхід RXD асинхронний щодо clk, тому він проходить
--      через 2-тригерний синхронізатор (rx_meta -> rx_sync), що усуває
--      метастабільність. Третій тригер rx_prev потрібен для виявлення
--      спаду '1' -> '0' (початок старт-біта).
--   2. Передискретизація x16. Лінія аналізується на імпульсах tick
--      (частота 16 * BAUD); один біт = 16 імпульсів tick.
--   3. Перевірка старт-біта. Після спаду відлічується OVERSAMPLE/2 = 8 tick
--      (середина старт-біта). Якщо лінія все ще '0' — старт справжній,
--      інакше це завада («глітч») і автомат повертається в IDLE.
--   4. Прийом даних. Від середини старт-біта відлічується по 16 tick,
--      тобто кожен біт даних вибирається точно в середині свого інтервалу,
--      що дає максимальний запас на розбіжність швидкостей (~±4..5 %).
--      Біти вдвигаються у зсувний регістр справа наліво (LSB first).
--   5. Стоп-біт. У середині стоп-біта лінія повинна бути '1'. Якщо так —
--      байт копіюється в rx_data і видається імпульс rx_valid; інакше —
--      імпульс rx_frame_err (помилка кадру), rx_data не змінюється.
--   6. Після вибірки стоп-біта автомат одразу переходить в IDLE (з середини
--      стоп-біта), що дозволяє приймати кадри «впритул» один за одним.
--      Новий кадр розпізнається лише по спаду лінії, тому після помилки
--      кадру (лінія = '0') хибного старту не виникає.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx is
    generic (
        OVERSAMPLE : positive := 16            -- імпульсів tick на один біт
    );
    port (
        clk          : in  std_logic;                     -- системний такт
        rst          : in  std_logic;                     -- синхронне скидання ('1')
        tick         : in  std_logic;                     -- дозвіл x16 від baud_gen
        rxd          : in  std_logic;                     -- асинхронний вхід UART RXD
        rx_data      : out std_logic_vector(7 downto 0);  -- останній прийнятий байт
        rx_valid     : out std_logic;                     -- імпульс (1 такт): новий байт
        rx_frame_err : out std_logic;                     -- імпульс (1 такт): стоп-біт = '0'
        state_dbg    : out std_logic_vector(1 downto 0);  -- код стану FSM:
                                                          -- 00 IDLE, 01 START,
                                                          -- 10 DATA, 11 STOP
        sample_dbg   : out std_logic                      -- імпульс у момент вибірки
                                                          -- біта (для осцилограм)
    );
end entity uart_rx;

architecture rtl of uart_rx is

    -- Стани автомата приймача
    type rx_state_t is (IDLE, START, DATA, STOP);
    signal state : rx_state_t := IDLE;

    -- Синхронізатор (2 тригери) + тригер для виявлення спаду.
    -- Початкове значення '1' — лінія UART у спокої.
    signal rx_meta : std_logic := '1';   -- 1-й тригер (може бути метастабільним)
    signal rx_sync : std_logic := '1';   -- 2-й тригер (стабільне значення)
    signal rx_prev : std_logic := '1';   -- значення rx_sync у попередньому такті

    -- Лічильник імпульсів tick у межах біта: 0 .. OVERSAMPLE-1
    signal tick_cnt : natural range 0 to OVERSAMPLE - 1 := 0;
    -- Номер біта даних, що приймається: 0 .. 7
    signal bit_idx  : natural range 0 to 7 := 0;
    -- Зсувний регістр прийому (новий біт входить у старший розряд,
    -- після 8 зсувів D0 опиняється в shreg(0))
    signal shreg    : std_logic_vector(7 downto 0) := (others => '0');
    -- Вихідні регістри
    signal data_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal valid_reg  : std_logic := '0';
    signal ferr_reg   : std_logic := '0';
    signal sample_reg : std_logic := '0';

begin

    rx_data      <= data_reg;
    rx_valid     <= valid_reg;
    rx_frame_err <= ferr_reg;
    sample_dbg   <= sample_reg;

    with state select state_dbg <=
        "00" when IDLE,
        "01" when START,
        "10" when DATA,
        "11" when STOP;

    ----------------------------------------------------------------------------
    -- Синхронізатор вхідної лінії (2 FF) + затримка для детектора спаду
    ----------------------------------------------------------------------------
    p_sync : process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rx_meta <= '1';
                rx_sync <= '1';
                rx_prev <= '1';
            else
                rx_meta <= rxd;
                rx_sync <= rx_meta;
                rx_prev <= rx_sync;
            end if;
        end if;
    end process p_sync;

    ----------------------------------------------------------------------------
    -- Автомат приймача
    ----------------------------------------------------------------------------
    p_fsm : process (clk)
    begin
        if rising_edge(clk) then
            -- Імпульсні виходи за замовчуванням неактивні
            valid_reg  <= '0';
            ferr_reg   <= '0';
            sample_reg <= '0';

            if rst = '1' then
                state    <= IDLE;
                tick_cnt <= 0;
                bit_idx  <= 0;
                shreg    <= (others => '0');
                data_reg <= (others => '0');
            else
                case state is

                    -- IDLE: чекаємо спаду лінії 1 -> 0 (можливий старт-біт)
                    when IDLE =>
                        if rx_prev = '1' and rx_sync = '0' then
                            tick_cnt <= 0;
                            state    <= START;
                        end if;

                    -- START: відлічуємо пів біта і перевіряємо, що лінія = '0'
                    when START =>
                        if tick = '1' then
                            if tick_cnt = OVERSAMPLE / 2 - 1 then
                                sample_reg <= '1';
                                tick_cnt   <= 0;
                                if rx_sync = '0' then
                                    bit_idx <= 0;
                                    state   <= DATA;   -- старт підтверджено
                                else
                                    state   <= IDLE;   -- завада, хибний старт
                                end if;
                            else
                                tick_cnt <= tick_cnt + 1;
                            end if;
                        end if;

                    -- DATA: через кожні OVERSAMPLE tick (середина біта)
                    -- вибираємо біт і вдвигаємо його в регістр (LSB first)
                    when DATA =>
                        if tick = '1' then
                            if tick_cnt = OVERSAMPLE - 1 then
                                sample_reg <= '1';
                                tick_cnt   <= 0;
                                shreg      <= rx_sync & shreg(7 downto 1);
                                if bit_idx = 7 then
                                    state <= STOP;
                                else
                                    bit_idx <= bit_idx + 1;
                                end if;
                            else
                                tick_cnt <= tick_cnt + 1;
                            end if;
                        end if;

                    -- STOP: у середині стоп-біта перевіряємо, що лінія = '1'
                    when STOP =>
                        if tick = '1' then
                            if tick_cnt = OVERSAMPLE - 1 then
                                sample_reg <= '1';
                                tick_cnt   <= 0;
                                if rx_sync = '1' then
                                    data_reg  <= shreg;   -- байт прийнято
                                    valid_reg <= '1';
                                else
                                    ferr_reg  <= '1';     -- помилка кадру
                                end if;
                                state <= IDLE;
                            else
                                tick_cnt <= tick_cnt + 1;
                            end if;
                        end if;

                end case;
            end if;
        end if;
    end process p_fsm;

end architecture rtl;
