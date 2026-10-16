// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dual-port RAM, one clock: port A reads and writes, port B only reads.
// Quartus's true dual-port template with port B's write tied off; port A
// returns the written data on a write, port B the old data.

module gx_tdpram #(
    parameter int AW = 10,
    parameter int DW = 8
) (
    input                 clk,
    input                 we_a,
    input      [AW-1:0]   a,
    input      [DW-1:0]   d,
    output reg [DW-1:0]   qa,
    input      [AW-1:0]   b,
    output reg [DW-1:0]   qb
);

reg [DW-1:0] mem [0:(1 << AW) - 1];

always @(posedge clk) begin
    if (we_a) begin
        mem[a] <= d;
        qa     <= d;
    end else
        qa <= mem[a];
end

always @(posedge clk) qb <= mem[b];

endmodule
