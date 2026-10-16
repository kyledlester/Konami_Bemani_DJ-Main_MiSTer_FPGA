// SPDX-License-Identifier: GPL-3.0-or-later
//
// Simple dual-port RAM, one clock: one write port, one registered read port.
// Quartus's own inference template, kept in a module of its own so that what
// surrounds a memory cannot stop it being inferred -- gx_tilemap's line
// buffers, written inline, came out of Quartus 17 as ~24K ALMs of logic.
// Read-during-write to the same address returns the old data.

module gx_sdpram #(
    parameter int AW = 10,
    parameter int DW = 8
) (
    input                 clk,
    input                 we,
    input      [AW-1:0]   wa,
    input      [DW-1:0]   d,
    input      [AW-1:0]   ra,
    output reg [DW-1:0]   q
);

reg [DW-1:0] mem [0:(1 << AW) - 1];

always @(posedge clk) begin
    if (we) mem[wa] <= d;
    q <= mem[ra];
end

endmodule
