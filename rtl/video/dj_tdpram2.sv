// SPDX-License-Identifier: GPL-3.0-or-later
//
// True dual-port RAM, one clock, both ports read and write (Quartus's
// template). Each port returns the old data on its own write.

module dj_tdpram2 #(
    parameter int AW = 10,
    parameter int DW = 8
) (
    input                 clk,
    input                 we_a,
    input      [AW-1:0]   a,
    input      [DW-1:0]   da,
    output reg [DW-1:0]   qa,
    input                 we_b,
    input      [AW-1:0]   b,
    input      [DW-1:0]   db,
    output reg [DW-1:0]   qb
);

reg [DW-1:0] mem [0:(1 << AW) - 1];

always @(posedge clk) begin
    if (we_a) mem[a] <= da;
    qa <= mem[a];
end

always @(posedge clk) begin
    if (we_b) mem[b] <= db;
    qb <= mem[b];
end

endmodule
