`timescale 1ns / 1ps

module skill_slot #(
	parameter ENABLE = 0,
	parameter DURATION = 0,
	parameter CHARGE_MAX = 5
)(
	input clk,
	input resetn,
	input sec_tick,
	input restart,
	input btn_skill,
	input [2:0] skill_charge,

	output reg [7:0] skill_timer,
	output skill_on,
	output skill_start
);
reg btn_q;

assign skill_on = skill_timer != 0;
assign skill_start = ENABLE && btn_skill && !btn_q &&
					 skill_charge >= CHARGE_MAX && !skill_on;

always @(posedge clk) begin
	if (!resetn) begin
		skill_timer <= 0;
		btn_q <= 0;
	end else if (restart) begin
		skill_timer <= 0;
		btn_q <= 0;
	end else begin
		btn_q <= btn_skill;

		if (skill_start) begin
			skill_timer <= DURATION[7:0];
		end else if (sec_tick && skill_timer != 0) begin
			skill_timer <= skill_timer - 1;
		end
	end
end

endmodule
