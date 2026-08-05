`timescale 1ns / 1ps

// One shared debounce timebase. Emits a one-clock `tick` every DEBOUNCE_CYCLES
// (~8 ms at 25.175 MHz). All four buttons sample on this single tick instead
// of each running their own 18-bit counter, which is a big logic saving on the
// nearly-full 4K. Debounce behaviour is unchanged: an output only ever moves at
// a tick boundary, so bounce (well under one window) is ignored and any real
// press (tens of ms) is caught.
module debounce_tick #(
	parameter DEBOUNCE_CYCLES = 200000,
	parameter CNT_BITS = $clog2(DEBOUNCE_CYCLES)
) (
	input clk,
	input resetn,
	output reg tick
);

reg [CNT_BITS-1:0] cnt;

always @(posedge clk) begin
	if (!resetn) begin
		cnt  <= 0;
		tick <= 0;
	end else if (cnt == DEBOUNCE_CYCLES - 1) begin
		cnt  <= 0;
		tick <= 1'b1;
	end else begin
		cnt  <= cnt + 1'b1;
		tick <= 1'b0;
	end
end

endmodule

// Per-button sampler: on the shared tick, adopt the (active-low) input state.
module debounce_sync (
	input clk,
	input resetn,
	input tick,
	input in,
	output reg out
);

always @(posedge clk) begin
	if (!resetn)
		out <= 1'b0;
	else if (tick)
		out <= ~in;
end

endmodule
