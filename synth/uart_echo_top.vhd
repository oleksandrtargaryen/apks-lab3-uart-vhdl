--------------------------------------------------------------------------------
-- Файл        : uart_echo_top.vhd
-- Проєкт      : Лабораторна робота №3 — UART на VHDL (варіант 1), етап 4
-- Автор       : Бартошко Олександр Ігорович, група КІ-408
--
-- Призначення : Верхній рівень для синтезу на ПЛІС Lattice iCE40 HX8K (ct256).
--               Обгортка uart_top у режимі «луна» (echo): кожен прийнятий
--               байт одразу передається назад, а також відображається на
--               8 світлодіодах. Завдяки цьому вся логіка Tx і Rx має
--               спостережувані виходи і не видаляється синтезатором,
--               а зовнішніх виводів лише 12 (clk, rst_n, rx, tx, led[7:0]).
--
--   rst_n — кнопка скидання, активний рівень '0' (у .pcf увімкнено pull-up);
--           проходить через 2-тригерний синхронізатор скидання.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;

entity uart_echo_top is
    generic (
        CLK_FREQ : positive := 50_000_000;   -- частота зовнішнього генератора, Гц
        BAUD     : positive := 115_200       -- швидкість UART, бод
    );
    port (
        clk   : in  std_logic;                     -- системний такт 50 МГц
        rst_n : in  std_logic;                     -- скидання, активний '0'
        rx    : in  std_logic;                     -- UART RXD (від USB-UART)
        tx    : out std_logic;                     -- UART TXD (до USB-UART)
        led   : out std_logic_vector(7 downto 0)   -- останній прийнятий байт
    );
end entity uart_echo_top;

architecture rtl of uart_echo_top is
    signal rst_sync : std_logic_vector(1 downto 0) := (others => '1'); -- синхронізатор скидання
    signal rst      : std_logic;
    signal rx_data  : std_logic_vector(7 downto 0);
    signal rx_valid : std_logic;
    signal rx_ferr  : std_logic;
    signal tx_busy  : std_logic;
    signal tx_done  : std_logic;
    signal led_reg  : std_logic_vector(7 downto 0) := (others => '0');
begin

    -- Синхронізатор скидання: асинхронна кнопка -> синхронний rst
    p_rst : process (clk)
    begin
        if rising_edge(clk) then
            rst_sync <= rst_sync(0) & (not rst_n);
        end if;
    end process p_rst;
    rst <= rst_sync(1);

    -- UART-ядро: прийнятий байт (rx_valid) одразу подається на передавач
    u_uart : entity work.uart_top
        generic map (
            CLK_FREQ   => CLK_FREQ,
            BAUD       => BAUD,
            OVERSAMPLE => 16
        )
        port map (
            clk          => clk,
            rst          => rst,
            tx_start     => rx_valid,
            tx_data      => rx_data,
            tx_busy      => tx_busy,
            tx_done      => tx_done,
            rx_data      => rx_data,
            rx_valid     => rx_valid,
            rx_frame_err => rx_ferr,
            uart_txd     => tx,
            uart_rxd     => rx
        );

    -- Регістр світлодіодів: останній коректно прийнятий байт
    p_led : process (clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                led_reg <= (others => '0');
            elsif rx_valid = '1' then
                led_reg <= rx_data;
            end if;
        end if;
    end process p_led;
    led <= led_reg;

end architecture rtl;
