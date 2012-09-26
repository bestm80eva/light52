--------------------------------------------------------------------------------
-- light52_mcu.vhdl -- MCU/SoC built around light52 CPU.
--------------------------------------------------------------------------------
-- FIXME add SFR table and peripheral list.
-- FIXME explain generics and interface signals.
--------------------------------------------------------------------------------
-- Copyright (C) 2012 Jose A. Ruiz
--                                                              
-- This source file may be used and distributed without         
-- restriction provided that this copyright statement is not    
-- removed from the file and that any derivative work contains  
-- the original copyright notice and the associated disclaimer. 
--                                                              
-- This source file is free software; you can redistribute it   
-- and/or modify it under the terms of the GNU Lesser General   
-- Public License as published by the Free Software Foundation; 
-- either version 2.1 of the License, or (at your option) any   
-- later version.                                               
--                                                              
-- This source is distributed in the hope that it will be       
-- useful, but WITHOUT ANY WARRANTY; without even the implied   
-- warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR      
-- PURPOSE.  See the GNU Lesser General Public License for more 
-- details.                                                     
--                                                              
-- You should have received a copy of the GNU Lesser General    
-- Public License along with this source; if not, download it   
-- from http://www.opencores.org/lgpl.shtml
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.light52_pkg.all;
use work.obj_code_pkg.all;


entity light52_mcu is
    generic (
        CODE_ROM_SIZE :         integer := 1024;
        XDATA_RAM_SIZE :        integer := 512; -- FIXME default should be zero
        OBJ_CODE :              t_obj_code := default_object_code;
        UART_HARDWIRED :        boolean := false;
        UART_BAUD_RATE :        integer := 19200;
        UART_CLOCK_RATE :       integer := 50e6
    );
    port(
        clk             : in std_logic;
        reset           : in std_logic;
                       
        rxd             : in std_logic;
        txd             : out std_logic;
        
        p0_out          : out std_logic_vector(7 downto 0);
        p1_out          : out std_logic_vector(7 downto 0);
        p2_in           : in std_logic_vector(7 downto 0);
        p3_in           : in std_logic_vector(7 downto 0)                       
    );
end entity light52_mcu;


architecture rtl of light52_mcu is

---- SFR addresses -------------------------------------------------------------

subtype t_mcu_sfr_addr is std_logic_vector(7 downto 0);

-- These include only the SFR addresses of the MCU peripherals; the CPU SFRs are
-- covered in the main package.
-- Note these addresses overlap those of the original 8051 but the SFRs 
-- themselves are NOT compatible!
constant SFR_ADDR_SCON      : t_mcu_sfr_addr := X"98";
constant SFR_ADDR_SBUF      : t_mcu_sfr_addr := X"99";
constant SFR_ADDR_SBPL      : t_mcu_sfr_addr := X"9a";
constant SFR_ADDR_SBPH      : t_mcu_sfr_addr := X"9b";
constant SFR_ADDR_P0        : t_mcu_sfr_addr := X"80";
constant SFR_ADDR_P1        : t_mcu_sfr_addr := X"90";
constant SFR_ADDR_P2        : t_mcu_sfr_addr := X"a0";
constant SFR_ADDR_P3        : t_mcu_sfr_addr := X"b0";
constant SFR_ADDR_TCON      : t_mcu_sfr_addr := X"88";
constant SFR_ADDR_TDATA     : t_mcu_sfr_addr := X"8a";

constant P0_RESET_VALUE     : std_logic_vector(7 downto 0) := X"00";
constant P1_RESET_VALUE     : std_logic_vector(7 downto 0) := X"00";


----- XCODE interface ----------------------------------------------------------

signal code_addr :          std_logic_vector(15 downto 0);
signal code_rd :            std_logic_vector(7 downto 0);

-- Code ROM must be initialized with the object code.
signal code_bram :          t_bram(0 to CODE_ROM_SIZE-1) := 
                            objcode_to_bram(OBJ_CODE, CODE_ROM_SIZE);
signal code_addr_slice :    std_logic_vector(log2(CODE_ROM_SIZE)-1 downto 0);


---- XDATA interface -----------------------------------------------------------

signal xdata_addr :         std_logic_vector(15 downto 0);
signal xdata_rd :           std_logic_vector(7 downto 0);
signal xdata_wr :           std_logic_vector(7 downto 0);
signal xdata_vma :          std_logic;
signal xdata_we :           std_logic;

signal xdata_ram :          t_bram(0 to XDATA_RAM_SIZE-1);
signal data_addr_slice :    std_logic_vector(log2(XDATA_RAM_SIZE)-1 downto 0);

---- SFR and peripheral module interface signals -------------------------------

signal sfr_addr :           std_logic_vector(7 downto 0);
signal sfr_rd :             std_logic_vector(7 downto 0);
signal sfr_wr :             std_logic_vector(7 downto 0);
signal sfr_vma :            std_logic;
signal sfr_we :             std_logic;

signal uart_re :            std_logic;
signal uart_ce :            std_logic;
signal uart_sfr_rd :        std_logic_vector(7 downto 0);
signal uart_irq :           std_logic;

signal timer_we :           std_logic;
signal timer_ce :           std_logic;
signal timer_sfr_rd :       std_logic_vector(7 downto 0);
signal timer_irq :          std_logic;

signal io_ce :              std_logic;
signal p0_reg :             std_logic_vector(7 downto 0);
signal p1_reg :             std_logic_vector(7 downto 0);
signal p2_reg :             std_logic_vector(7 downto 0);
signal p3_reg :             std_logic_vector(7 downto 0);

signal irq_source :         std_logic_vector(4 downto 0);

begin

cpu: entity work.light52_cpu 
port map (
    clk         => clk,
    reset       => reset,
    
    code_addr   => code_addr,
    code_rd     => code_rd,

    irq_source  => irq_source,
    
    xdata_addr  => xdata_addr,
    xdata_rd    => xdata_rd,
    xdata_wr    => xdata_wr,
    xdata_vma   => xdata_vma,
    xdata_we    => xdata_we,

    
    sfr_addr    => sfr_addr,
    sfr_rd      => sfr_rd,
    sfr_wr      => sfr_wr,
    sfr_vma     => sfr_vma,
    sfr_we      => sfr_we
);

-- FIXME uart irq missing
irq_source <= "000" & timer_irq & "0";

--------------------------------------------------------------------------------

code_addr_slice <= code_addr(code_addr_slice'high downto 0);

code_ram_block:
process(clk)
begin
    if clk'event and clk='1' then
        code_rd <= code_bram(to_integer(unsigned(code_addr_slice)));
    end if;
end process code_ram_block;

--------------------------------------------------------------------------------

data_addr_slice <= xdata_addr(data_addr_slice'high downto 0);

xdata_ram_block:
process(clk)
begin
    if clk'event and clk='1' then
        if xdata_we='1' then
            xdata_ram(to_integer(unsigned(data_addr_slice))) <= xdata_wr;
        end if;
        xdata_rd <= xdata_ram(to_integer(unsigned(data_addr_slice)));
    end if;
end process xdata_ram_block;

--------------------------------------------------------------------------------

-- SFR input multiplexor -- modify simplified addressing if you add peripherals.
with sfr_addr(7 downto 3) select sfr_rd <=
    uart_sfr_rd     when SFR_ADDR_SCON(7 downto 3),
    timer_sfr_rd    when SFR_ADDR_TCON(7 downto 3),
    p0_reg          when SFR_ADDR_P0(7 downto 3),
    p1_reg          when SFR_ADDR_P1(7 downto 3),
    p2_reg          when SFR_ADDR_P2(7 downto 3),
    p3_reg          when others;

---- UART ----------------------------------------------------------------------

uart : entity work.light52_uart
generic map (
    HARDWIRED => UART_HARDWIRED,
    CLOCK_FREQ => UART_CLOCK_RATE,
    BAUD_RATE => UART_BAUD_RATE
)
port map (
    rxd_i   => rxd,
    txd_o   => txd,
    
    irq_o   => uart_irq,
    
    data_i  => sfr_wr,
    data_o  => uart_sfr_rd,
    
    addr_i  => sfr_addr(1 downto 0),
    wr_i    => sfr_we,
    rd_i    => uart_re,
    ce_i    => uart_ce,
    
    clk_i   => clk,
    reset_i => reset
);

-- Make sure the simplifications we'll do in the address decoding are valid.
assert SFR_ADDR_SCON=X"98" and SFR_ADDR_SBUF=X"99" and 
       SFR_ADDR_SBPL=X"9a" and SFR_ADDR_SBPH=X"9b"
report "MCU SFR address decoding assumes standard UART register addresses "&
       "but addresses configured in light52_mcu are not standard."
severity failure;

uart_ce <= '1' when sfr_addr(7 downto 3)=SFR_ADDR_SCON(7 downto 3) else '0';
uart_re <= sfr_vma and not sfr_we;


---- Timer (basic 8 bit timer) -------------------------------------------------

timer: entity work.light52_timer8
generic map (
    PRESCALER_STAGES => 1
)
port map (
    irq_o   => timer_irq,
    
    data_i  => sfr_wr,
    data_o  => timer_sfr_rd,
    
    addr_i  => sfr_addr(1),
    wr_i    => timer_we,
    ce_i    => timer_ce,
    
    clk_i   => clk,
    reset_i => reset
);

timer_ce <= '1' when sfr_addr(7 downto 3)=SFR_ADDR_TCON(7 downto 3) else '0';
timer_we <= sfr_we;

-- Make sure the simplifications we'll do in the address decoding are valid.
assert SFR_ADDR_TCON=X"88" and SFR_ADDR_TDATA=X"8a"
report "MCU SFR address decoding assumes standard TIMER0 register addresses "&
       "but addresses configured in light52_mcu are not standard."
severity failure;


---- Input/Output ports --------------------------------------------------------

-- Make sure the simplifications we'll do in the address decoding are valid.
assert SFR_ADDR_P0=X"80" and SFR_ADDR_P1=X"90" and 
       SFR_ADDR_P2=X"a0" and SFR_ADDR_P3=X"b0"
report "MCU SFR address decoding assumes I/O port addresses are standard "&
       "but addresses configured in light52_pkg are not."
severity failure;

io_ce <= '1' when sfr_addr(7 downto 6)=SFR_ADDR_P0(7 downto 6) and 
                  sfr_addr(3 downto 0)="0000" and
                  sfr_vma='1'
                  else '0';

output_ports:
process(clk)
begin
    if clk'event and clk='1' then
        if reset='1' then 
            p0_reg <= P0_RESET_VALUE;
            p1_reg <= P1_RESET_VALUE;
        else
            if io_ce='1' and sfr_we='1' then
                if sfr_addr(5 downto 4)=SFR_ADDR_P0(5 downto 4) then
                    p0_reg <= sfr_wr;
                end if;
                if sfr_addr(5 downto 4)=SFR_ADDR_P1(5 downto 4) then
                    p1_reg <= sfr_wr;
                end if;
            end if;
        end if;
    end if;
end process output_ports;

-- Note that for output ports the CPU will ALWAYS read the output register and
-- not the actual pin status -- like read-modify-write instructions in the
-- original MCS51.
p0_out <= p0_reg;
p1_out <= p1_reg;

-- NOTE: input ports are registered but NOT protected against metastability.
-- Add a second layer of registers if your application needs the protection.
input_ports:
process(clk)
begin
    if clk'event and clk='1' then
        p2_reg <= p2_in;
        p3_reg <= p3_in;
    end if;
end process input_ports;


end architecture rtl;