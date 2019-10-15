// __module info begin__
// name     : barrel_shifter
// function : shift the register by custom bitwidth
// __module info end__

module barrel_shifter
# (
  parameter w = 32
)
(
  input           clk,
  input           rst_n,
  input  [w-1:0]  up_dat,
  output [w-1:0]  dn_dat,
  input  [4:0]    ctrl
); // fifo

genvar i;

wire  [w-1:0] reverse_in;
wire  [w-1:0] shift_8;
wire  [w-1:0] shift_4;
wire  [w-1:0] shift_2;
wire  [w-1:0] shift_1;
wire  [w-1:0] reverse_out;


// =========================================================================== //
// Data reverse for input data
// =========================================================================== //
generate
for(i=0; i<w; i=i+1)
begin : DATA_REVERSE_IN
    mux2_1 u_data_reverse_in (up_dat[i], up_dat[w-1-i], ctrl[4], reverse_in[i]);
end
endgenerate


// =========================================================================== //
// Shifter by 8 bits
// =========================================================================== //
generate
for(i=0; i<w-8; i=i+1)
begin : SHIFT8_BITS
    mux2_1 u_mux_shift8_bits (reverse_in[i], reverse_in[i+8], ctrl[3], shift_8[i]);
end
endgenerate

generate
for(i=w-8; i<w; i=i+1)
begin : SHIFT8_ZERO
    mux2_1 u_mux_shift8_zero (reverse_in[i], 1'b0, ctrl[3], shift_8[i]);
end
endgenerate


// =========================================================================== //
// Shifter by 4 bits
// =========================================================================== //
generate
for(i=0; i<w-4; i=i+1)
begin : SHIFT4_BITS
    mux2_1 u_mux_shift4_bits (shift_8[i], up_dat[i+4], ctrl[2], shift_4[i]);
end
endgenerate

generate
for(i=w-4; i<w; i=i+1)
begin : SHIFT4_ZERO
    mux2_1 u_mux_shift4_zero (shift_8[i], 1'b0, ctrl[2], shift_4[i]);
end
endgenerate


// =========================================================================== //
// Shifter by 2 bits
// =========================================================================== //
generate
for(i=0; i<w-2; i=i+1)
begin : SHIFT2_BITS
    mux2_1 u_mux_shift2_bits (shift_4[i], up_dat[i+2], ctrl[1], shift_2[i]);
end
endgenerate

generate
for(i=w-2; i<w; i=i+1)
begin : SHIFT2_ZERO
    mux2_1 u_mux_shift2_zero (shift_4[i], 1'b0, ctrl[1], shift_2[i]);
end
endgenerate



// =========================================================================== //
// Shifter by 1 bits
// =========================================================================== //
generate
for(i=0; i<w-1; i=i+1)
begin : SHIFT1_BITS
    mux2_1 u_mux_shift1_bits (shift_2[i], up_dat[i+1], ctrl[0], shift_1[i]);
end
endgenerate

generate
for(i=w-1; i<w; i=i+1)
begin : SHIFT1_ZERO
    mux2_1 u_mux_shift1_zero (shift_2[i], 1'b0, ctrl[0], shift_1[i]);
end
endgenerate

// =========================================================================== //
// Data reverse for output data
// =========================================================================== //
generate
for(i=0; i<w; i=i+1)
begin : DATA_REVERSE_OUT
    mux2_1 u_data_reverse_out (shift_1[i], shift_1[w-1-i], ctrl[4], reverse_out[i]);
end
endgenerate

assign dn_dat = reverse_out;

endmodule // fifo
