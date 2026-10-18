--------------------------------------------------------------------------------
-- Файл        : uart_top.vhd
-- Проєкт      : Лабораторна робота №3 — UART на VHDL (варіант 1)
-- Автор       : Бартошко Олександр Ігорович, група КІ-408
--
-- Призначення : Верхній рівень UART-ядра. Об'єднує:
--                 * baud_gen — спільний генератор імпульсів tick (BAUD x16);
--                 * uart_tx  — передавач 8N1;
--                 * uart_rx  — приймач 8N1 з 16-кратною передискретизацією.
--               Передавач і приймач працюють незалежно (повний дуплекс).
--
--                        +-----------+  tick
--               clk ---->| baud_gen  |--------+------------+
--                        +-----------+        |            |
--                                        +----v----+  +----v----+
--      tx_start, tx_data --------------->| uart_tx |  | uart_rx |<---- uart_rxd
--      tx_busy, tx_done <----------------|         |  |         |----> rx_data,
--                          uart_txd <----|         |  |         |      rx_valid,
--                                        +---------+  +---------+      rx_frame_err
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity uart_top is
    generic (
        CLK_FREQ   : positive := 50_000_000;  -- частота системного такту, Гц
        BAUD       : positive := 115_200;     -- баудова швидкість, біт/с
        OVERSAMPLE : positive := 16           -- передискретизація приймача
    );
    port (
        clk          : in  std_logic;                     -- системний такт 50 МГц
        rst          : in  std_logic;                     -- синхронне скидання ('1')
        -- Інтерфейс передавача (паралельна сторона)
        tx_start     : in  std_logic;                     -- запит передачі байта
        tx_data      : in  std_logic_vector(7 downto 0);  -- байт для передачі
        tx_busy      : out std_logic;                     -- передавач зайнятий
        tx_done      : out std_logic;                     -- кадр передано (імпульс)
        -- Інтерфейс приймача (паралельна сторона)
        rx_data      : out std_logic_vector(7 downto 0);  -- прийнятий байт
        rx_valid     : out std_logic;                     -- байт прийнято (імпульс)
        rx_frame_err : out std_logic;                     -- помилка кадру (імпульс)
        -- Послідовні лінії UART
        uart_txd     : out std_logic;                     -- вихід TXD
        uart_rxd     : in  std_logic                      -- вхід RXD
    );
end entity uart_top;

architecture rtl of uart_top is

    signal tick         : std_logic;                     -- імпульс дозволу x16
    signal tx_state_dbg : std_logic_vector(1 downto 0);  -- стан FSM Tx (налагодження)
    signal rx_state_dbg : std_logic_vector(1 downto 0);  -- стан FSM Rx (налагодження)
    signal rx_sample    : std_logic;                     -- момент вибірки Rx

begin

    -- Генератор баудової швидкості (спільний для Tx та Rx)
    u_baud : entity work.baud_gen
        generic map (
            CLK_FREQ   => CLK_FREQ,
            BAUD       => BAUD,
            OVERSAMPLE => OVERSAMPLE
        )
        port map (
            clk  => clk,
            rst  => rst,
            tick => tick
        );

    -- Передавач
    u_tx : entity work.uart_tx
        generic map (OVERSAMPLE => OVERSAMPLE)
        port map (
            clk       => clk,
            rst       => rst,
            tick      => tick,
            tx_start  => tx_start,
            tx_data   => tx_data,
            tx_busy   => tx_busy,
            tx_done   => tx_done,
            txd       => uart_txd,
            state_dbg => tx_state_dbg
        );

    -- Приймач
    u_rx : entity work.uart_rx
        generic map (OVERSAMPLE => OVERSAMPLE)
        port map (
            clk          => clk,
            rst          => rst,
            tick         => tick,
            rxd          => uart_rxd,
            rx_data      => rx_data,
            rx_valid     => rx_valid,
            rx_frame_err => rx_frame_err,
            state_dbg    => rx_state_dbg,
            sample_dbg   => rx_sample
        );

end architecture rtl;
