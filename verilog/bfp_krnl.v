// __module info begin__  
// name     : krnl
// function : 
// inputs   : in_data, weight
// outputs  : out_data
// document : 
// __module info end__

module bfp_krnl
# (
  // The parallism in channel direction
  parameter pc = 64,
  // The data width of input data
  parameter in_data_width=8,
  // The data width utilized for accumulated results
  parameter out_data_width=32
)
(
  input  wire                        clk,
  input  wire                        rst_n,

  // coefficients for the kernel, each in 8-bit unsigned int format
  input  wire  [pc*in_data_width-1:0]  coef,
  output  wire                          coef_rdy,
  input  wire                          coef_vld,
  // up stram data input, one transaction per input pixel
  input  wire                           up_vld,
  input  wire  [pc*in_data_width-1:0]  up_dat,
  output wire                           up_rdy,
  // zero point of the weights

  input wire    [4:0]               shift_bits,

  // filter_finish signal which indicates the data transfer for one filter completes
  input  wire                        filter_finish_data,
  // filter_finish signal which indicates the calculation for one filter completes
  // also used for data buffer module to update bias
  output wire                        filter_finish_cal,

  input  wire  [32-1:0]      bias_dat,
  input  wire                        bias_vld,
  // accumulation finish signal which indicates the accumulation result valid
  input  wire                           acc_result_vld,

  // down stream data output, one transaction per component of an output pixel
  output wire                        dn_vld,
  output wire  [in_data_width-1:0]    dn_dat,
  input  wire                        dn_rdy

);
wire                    ce_up_vld;
wire                    acc_result_vld_real;
wire                    ce_up_rdy;
assign acc_result_vld_real = acc_result_vld & up_vld & coef_vld;
// Only the up_vld is "&" with dn_rdy. But it is enough for SIF since only when
// both up_vld and coef_vld is high, the kernel will start compute, otherwise not.
// So controling up_vld is enough.
assign ce_up_vld = up_vld & dn_rdy;

assign up_rdy = ce_up_rdy & coef_vld & up_vld;
assign coef_rdy = up_rdy;

localparam PE = 4;
localparam ENABLE_8OUT = 1;
localparam LATENCY_ADD = 1;
localparam LATENCY_MUL = 2;

bfp_compute_engine #(
    .pc(pc),
    .pe(PE),
    .in_data_width(in_data_width),
    .out_data_width(out_data_width),
    .latency_add(LATENCY_ADD),
    .latency_mul(LATENCY_MUL),
    .bias_data_width(32)
) u_compute_engine
(
    .rst_n(rst_n),
    .clk(clk),
    .coef(coef),
    .coef_vld(coef_vld),
    .up_vld(ce_up_vld),
    .up_dat(up_dat),
    .up_rdy(ce_up_rdy),
    .shift_bits(shift_bits),
    .filter_finish_data(filter_finish_data),
    .filter_finish_cal(filter_finish_cal),
    .bias_dat(bias_dat),
    .bias_vld(bias_vld),
    .acc_result_vld(acc_result_vld_real),
    .dn_vld(dn_vld),
    .dn_dat(dn_dat),
    .dn_rdy(dn_rdy)
); 
endmodule