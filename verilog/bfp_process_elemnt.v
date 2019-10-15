// __module info begin__  
// name     : bfp_process_elemnt 
// function : perform the 8-bit mul-add between coef and input without data_sum
// inputs   : in_data, weight
// outputs  : out_data
// document : 
// __module info end__

module bfp_process_elemnt
# (
  // The processing element's parallism
  parameter pe = 4,
  // The data width of input data
  parameter in_data_width=8,
  // The data width utilized for accumulated results
  // The lower 18 bits is valid in 32in-1out mode
  parameter out_data_width=24
)
(
  input  wire                        clk,
  input  wire                        rst_n,

  // coefficients for the kernel, each in 8-bit unsigned int format
  input  wire  [pe*in_data_width-1:0]  coef,
  input  wire                          coef_vld,
  // up stram data input, one transaction per input pixel
  input  wire                           up_vld,
  input  wire  [pe*in_data_width-1:0]  up_dat,
  output wire                           up_rdy,

  // down stream data output, one transaction per component of an output pixel
  output wire                        dn_vld,
  output wire  [out_data_width-1:0]    dn_dat,
  input  wire                        dn_rdy

);

genvar i;

wire [in_data_width-1:0]           pixel_in[pe-1:0];
wire [in_data_width-1:0]           coeff_in[pe-1:0];

//Data register and Valid signal for mul results
wire [2*in_data_width-1:0]         mult_result[pe-1:0];
reg  [2*in_data_width-1:0]         mult_result_r[pe-1:0];

wire                            mult_result_vld[pe-1:0];
reg                             mult_result_vld_r[pe-1:0];

//Data register and Valid signal for the accumulation of mul results
wire [2*in_data_width:0]           accu_l1[(pe>>1)-1:0];
reg  [2*in_data_width:0]           accu_l1_r[(pe>>1)-1:0];

wire                            accu_l1_vld[(pe>>1)-1:0];
reg                             accu_l1_vld_r[(pe>>1)-1:0];

//Data register and Valid signal for the sif_mac
wire [2*in_data_width:0]           acc_sif_mac[(pe>>1)-1:0];
reg  [2*in_data_width:0]           acc_sif_mac_r[(pe>>1)-1:0];

wire                            acc_sif_mac_vld[(pe>>1)-1:0];
reg                             acc_sif_mac_vld_r[(pe>>1)-1:0];

//Register is inserted after every function unit for better timing performance
wire [2*in_data_width+1:0]           accu_l2[(pe>>2)-1:0];
reg  [2*in_data_width+1:0]           accu_l2_r[(pe>>2)-1:0];

wire                            accu_l2_vld[(pe>>2)-1:0];
reg                             accu_l2_vld_r[(pe>>2)-1:0];

wire [2*in_data_width+1:0]           final_dat;
reg  [2*in_data_width+1:0]           final_dat_r;

wire                            final_vld;
reg                             final_vld_r;

generate
for (i=0 ; i<pe; i=i+1)
begin : GENERATE_PIXEL_IN
    assign pixel_in[i] = up_dat[( in_data_width*i + in_data_width-1) : (in_data_width*i)];
    assign coeff_in[i] = coef[( in_data_width*i + in_data_width-1) : (in_data_width*i)];
end
endgenerate


// =========================================================================== //
//Perform pe number of multiplications between data and coefficient
// =========================================================================== //

generate
for(i=0 ; i<(pe/2) ; i=i+1)
begin : GENERATE_MULT_DATA
    sif_mac #(
        .WIDTH_A(in_data_width),
        .WIDTH_B(in_data_width),
        .WIDTH_S(2*in_data_width+1),
        .DSP_SW(1)
    ) u_sif_mac_data_coef
    (
        .rst_n(rst_n),
        .clk(clk),
        .a_vld(up_vld),
        .a_dat(pixel_in[2*i]),
        .a_rdy(),
        .b_vld(coef_vld),
        .b_dat(coeff_in[2*i]),
        .b_rdy(),
        .c_vld(up_vld),
        .c_dat(pixel_in[2*i+1]),
        .c_rdy(),
        .d_vld(coef_vld),
        .d_dat(coeff_in[2*i+1]),
        .d_rdy(),
        .s_vld(accu_l1_vld[i]),
        .s_dat(accu_l1[i]),
        .s_rdy(1'b1)
    ); // sif_mult
end
endgenerate

generate
for(i=0; i<(pe>>1); i=i+1)
begin : GENERATE_ACCU_REG_FIRST_LEVEL
    always @(posedge clk or negedge rst_n)
    if(!rst_n) begin
        accu_l1_r[i] <= 0;
        accu_l1_vld_r[i] <= 0; 
    end
    else if(accu_l1_vld[i]) begin
        accu_l1_r[i] <= accu_l1[i];
        accu_l1_vld_r[i] <= accu_l1_vld[i];
    end
    else begin
        accu_l1_r[i] <= 0;
        accu_l1_vld_r[i] <= 0; 
    end
end
endgenerate


// =========================================================================== //
// The second-lever adder in adder tree for the accumulation of mul results
// =========================================================================== //
generate
for(i=0; i<(pe>>2) ; i=i+1)
begin : SECOND_LEVEL_ADDER
    sif_add #(
        .WIDTH_A(2*in_data_width+1),
        .WIDTH_B(2*in_data_width+1),
        .WIDTH_S(2*in_data_width+2),
        .TYPE_SIGNAL(0),
        .TYPE_OP(0)
    ) u_sif_add_result_2level
    (
        .rst_n(rst_n),
        .clk(clk),
        .A_vld(accu_l1_vld_r[i]),
        .A_dat(accu_l1_r[i]),
        .A_rdy(),
        .B_vld(accu_l1_vld_r[(pe>>1)-1-i]),
        .B_dat(accu_l1_r[(pe>>1)-1-i]),
        .B_rdy(),
        .S_vld(accu_l2_vld[i]),
        .S_dat(accu_l2[i]),
        .S_rdy(1'b1),
        .overflow()
    ); // sif_add
end
endgenerate

generate
for(i=0; i<(pe>>2); i=i+1)
begin : GENERATE_ACCU_REG_SECOND_LEVEL
    always @(posedge clk or negedge rst_n)
    if(!rst_n) begin
        accu_l2_r[i] <= 0;
        accu_l2_vld_r[i] <= 0; 
    end
    else if(accu_l2_vld[i]) begin
        accu_l2_r[i] <= accu_l2[i];
        accu_l2_vld_r[i] <= accu_l2_vld[i];
    end
    else begin
        accu_l2_r[i] <= 0;
        accu_l2_vld_r[i] <= 0; 
    end
end
endgenerate

assign  dn_vld = accu_l2_vld_r[0];
assign  dn_dat = accu_l2_vld_r[0] ? accu_l2_r[0] : 0;

endmodule