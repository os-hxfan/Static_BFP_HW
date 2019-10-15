// __module info begin__  
// name     : compute_engine
// function : 
// inputs   : in_data, weight
// outputs  : out_data
// document : 
// __module info end__

module bfp_compute_engine
# (
  // The compute unit's parallism, which is equal to pc
  parameter pc = 32,
  // The processing element's parallism
  parameter pe = 4,
  // The data width of input data
  parameter in_data_width=8,
  // The data width utilized for accumulated results
  parameter out_data_width=24,
  // The latency of adder
  parameter latency_add=1,
  // The latency of multiplier
  parameter latency_mul=4,
  // The data width of bias
  parameter bias_data_width=32
)
(
  input  wire                        clk,
  input  wire                        rst_n,

  // coefficients for the kernel, each in 8-bit unsigned int format
  input  wire  [pc*in_data_width-1:0]  coef,
  input  wire                          coef_vld,
  // up stram data input, one transaction per input pixel
  input  wire                           up_vld,
  input  wire  [pc*in_data_width-1:0]  up_dat,
  output wire                           up_rdy,


  input wire    [4:0]               shift_bits,
  // filter_finish signal which indicates the data transfer for one filter completes
  input  wire                        filter_finish_data,
  // filter_finish signal which indicates the calculation for one filter completes
  // also used for data buffer module to update bias
  output wire                        filter_finish_cal,

  input  wire  [bias_data_width-1:0]      bias_dat,
  input  wire                        bias_vld,
  // accumulation finish signal which indicates the accumulation result valid
  input  wire                           acc_result_vld,

  // down stream data output, one transaction per component of an output pixel
  output wire                        dn_vld,
  output wire  [in_data_width-1:0]    dn_dat,
  input  wire                        dn_rdy

);

// The number of processing elements in one compute unit
localparam NUM_PE = pc / pe;
// The latency of computational engine ((pe+sub) + acc_pe + accu_channel)
localparam LATENCY_CU = ((latency_mul + 1) + ($clog2(pe) + 1) * (latency_add + 1)) +
    $clog2(NUM_PE) * (latency_add + 1);
// The latency of computational engine and the appended bias adder, 
// for filter_finish_cal
localparam LATENCY_CU_BIAS = LATENCY_CU + (latency_add);
// The depth of sif reg fifo. for safety, the depth is twice as the pipeline level

genvar i;

wire [pe*in_data_width-1:0]           pixel_in[NUM_PE-1:0];
wire [pe*in_data_width-1:0]           coeff_in[NUM_PE-1:0];

//Data register and Valid signal for the accumulation of mul results
wire [out_data_width-1:0]           mult_result[NUM_PE-1:0];
reg  [2*in_data_width+$clog2(pe)-1:0]           mult_result_r[NUM_PE-1:0];

wire                            mult_result_vld[NUM_PE-1:0];
reg                             mult_result_vld_r[NUM_PE-1:0];

reg  [2*in_data_width+$clog2(pe)-1:0]           mult_result_l1[NUM_PE-1:0];
reg                             mult_result_vld_l1[NUM_PE-1:0];
reg  [2*in_data_width+$clog2(pe)-1:0]           mult_result_l2[NUM_PE-1:0];
reg                             mult_result_vld_l2[NUM_PE-1:0];

//Data register and Valid signal for the accumulation of mul results
wire [2*in_data_width+$clog2(pe):0]           accu_l1[(NUM_PE>>1)-1:0];
reg  [2*in_data_width+$clog2(pe):0]           accu_l1_r[(NUM_PE>>1)-1:0];

wire                            accu_l1_vld[(NUM_PE>>1)-1:0];
reg                             accu_l1_vld_r[(NUM_PE>>1)-1:0];

// The data width is the multiplication plus second adder tree
wire [2*in_data_width+$clog2(pe)+1:0]           accu_l2[(NUM_PE>>2)-1:0];
reg  [2*in_data_width+$clog2(pe)+1:0]           accu_l2_r[(NUM_PE>>2)-1:0];

wire                            accu_l2_vld[(NUM_PE>>2)-1:0];
reg                             accu_l2_vld_r[(NUM_PE>>2)-1:0];

// The data width is the multiplication plus third adder tree
wire [2*in_data_width+$clog2(pe)+2:0]           accu_l3[(NUM_PE>>3)-1:0];
reg  [2*in_data_width+$clog2(pe)+2:0]           accu_l3_r[(NUM_PE>>3)-1:0];

wire                            accu_l3_vld[(NUM_PE>>3)-1:0];
reg                             accu_l3_vld_r[(NUM_PE>>3)-1:0];

// The data width is the multiplication plus fourth-level adder tree
wire [2*in_data_width+$clog2(pe)+3:0]           accu_l4[(NUM_PE>>4)-1:0];
reg  [2*in_data_width+$clog2(pe)+3:0]           accu_l4_r[(NUM_PE>>4)-1:0];

wire                            accu_l4_vld[(NUM_PE>>4)-1:0];
reg                             accu_l4_vld_r[(NUM_PE>>4)-1:0];

// The data width is the multiplication plus fifth-level adder tree
wire [2*in_data_width+$clog2(pe)+4:0]           accu_l5[(NUM_PE>>5)-1:0];
reg  [2*in_data_width+$clog2(pe)+4:0]           accu_l5_r[(NUM_PE>>5)-1:0];

wire                            accu_l5_vld[(NUM_PE>>5)-1:0];
reg                             accu_l5_vld_r[(NUM_PE>>5)-1:0];


// Data register and Valid signal for the accumulation of channel and position
wire [out_data_width-1:0]           accu_chnl;
reg  [out_data_width-1:0]           accu_chnl_r;

wire                            accu_chnl_vld;
reg                             accu_chnl_vld_r;

// The wire for partial result of channel accumulation
wire [out_data_width-1:0]           partial_result;
wire                            partial_result_vld;

// The wire for bias result of channel accumulation
wire [out_data_width-1:0]           bias_result_dat;
wire                            bias_result_vld;

// reg  [in_data_width-1:0]        zp_weight_dat_r;

reg  [LATENCY_CU-1:0]          acc_result_vld_r;
reg  [LATENCY_CU_BIAS-1:0]      filter_finish_data_r;
reg                            filter_finish_cal_r;

wire                            fifo_up_rdy;

// Hotfix for the bug which caused by acc_result update, 22/02/2019
reg first_dat_point;

// For result before quantization

wire  [bias_data_width-1:0]                    shifted_dat; 

// assign up_rdy = dn_rdy & fifo_up_rdy;
assign up_rdy = dn_rdy; //for timing improvement, needs to make sure 
assign data_sum_rdy = 1; 


// =========================================================================== //
// Generate the result from processing element
// =========================================================================== //
generate
for (i=0 ; i<NUM_PE; i=i+1)
begin : GENERATE_PIXEL_IN
    assign pixel_in[i] = up_dat[( pe*in_data_width*i + pe*in_data_width-1) : (pe*in_data_width*i)];
    assign coeff_in[i] = coef[( pe*in_data_width*i + pe*in_data_width-1) : (pe*in_data_width*i)];
end
endgenerate

generate
for(i=0; i<NUM_PE ; i=i+1)
begin : GENERATE_PE_DATA
    bfp_process_elemnt #(
        .pe(pe),
        .in_data_width(in_data_width),
        .out_data_width(out_data_width)
    ) u_process_elemnt_result
    (
        .rst_n(rst_n),
        .clk(clk),
        .coef(coeff_in[i]),
        .coef_vld(coef_vld),
        .up_vld(up_vld),
        .up_dat(pixel_in[i]),
        .up_rdy(),
        .dn_vld(mult_result_vld[i]),
        .dn_dat(mult_result[i]),
        .dn_rdy(1'b1)
    ); // sif_add
end
endgenerate

// =========================================================================== //
// Two stage pipeline
// =========================================================================== //


generate
for(i=0; i<NUM_PE; i=i+1)
begin : GENERATE_PE_REG_L1
    always @(posedge clk or negedge rst_n)
    if(!rst_n) begin
        mult_result_l1[i] <= 0;
        mult_result_vld_l1[i] <= 0; 
    end
    else if(mult_result_vld[i]) begin
        mult_result_l1[i] <= mult_result[i][2*in_data_width+$clog2(pe)-1:0];
        mult_result_vld_l1[i] <= mult_result_vld[i];
    end
    else begin
        mult_result_l1[i] <= 0;
        mult_result_vld_l1[i] <= 0; 
    end
end
endgenerate


generate
for(i=0; i<NUM_PE; i=i+1)
begin : GENERATE_PE_REG_L2
    always @(posedge clk or negedge rst_n)
    if(!rst_n) begin
        mult_result_l2[i] <= 0;
        mult_result_vld_l2[i] <= 0; 
    end
    else if(mult_result_vld_l1[i]) begin
        mult_result_l2[i] <= mult_result_l1[i];
        mult_result_vld_l2[i] <= mult_result_vld_l1[i];
    end
    else begin
        mult_result_l2[i] <= 0;
        mult_result_vld_l2[i] <= 0; 
    end
end
endgenerate

// =========================================================================== //
// For timing, two stage pipeline
// =========================================================================== //


generate
for(i=0; i<NUM_PE; i=i+1)
begin : GENERATE_PE_REG
    always @(posedge clk or negedge rst_n)
    if(!rst_n) begin
        mult_result_r[i] <= 0;
        mult_result_vld_r[i] <= 0; 
    end
    else if(mult_result_vld_l2[i]) begin
        mult_result_r[i] <= mult_result_l2[i];
        mult_result_vld_r[i] <= mult_result_vld_l2[i];
    end
    else begin
        mult_result_r[i] <= 0;
        mult_result_vld_r[i] <= 0; 
    end
end
endgenerate

// =========================================================================== //
// Use adder tree to accumulate the mul_results
// The first-lever adder in adder tree for the accumulation of mul results
// =========================================================================== //
generate
for(i=0; i<(NUM_PE>>1) ; i=i+1)
begin : FIRST_LEVEL_ADDER
    sif_add #(
        .WIDTH_A(2*in_data_width+$clog2(pe)),
        .WIDTH_B(2*in_data_width+$clog2(pe)),
        .WIDTH_S(2*in_data_width+$clog2(pe)+1),
        .TYPE_SIGNAL(0),
        .TYPE_OP(0)
    ) u_sif_add_result_1st
    (
        .rst_n(rst_n),
        .clk(clk),
        .A_vld(mult_result_vld_r[i]),
        .A_dat(mult_result_r[i]),
        .A_rdy(),
        .B_vld(mult_result_vld_r[NUM_PE-1-i]),
        .B_dat(mult_result_r[NUM_PE-1-i]),
        .B_rdy(),
        .S_vld(accu_l1_vld[i]),
        .S_dat(accu_l1[i]),
        .S_rdy(1'b1),
        .overflow()
    ); // sif_add
end
endgenerate

generate
for(i=0; i<(NUM_PE>>1); i=i+1)
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
if (pc>8) begin : SELECT_SECOND_LEVEL_ADDER
    for(i=0; i<(NUM_PE>>2) ; i=i+1)
    begin : SECOND_LEVEL_ADDER
        sif_add #(
            .WIDTH_A(2*in_data_width+$clog2(pe)+1),
            .WIDTH_B(2*in_data_width+$clog2(pe)+1),
            .WIDTH_S(2*in_data_width+$clog2(pe)+2),
            .TYPE_SIGNAL(0),
            .TYPE_OP(0)
        ) u_sif_add_result_2nd
        (
            .rst_n(rst_n),
            .clk(clk),
            .A_vld(accu_l1_vld_r[i]),
            .A_dat(accu_l1_r[i]),
            .A_rdy(),
            .B_vld(accu_l1_vld_r[(NUM_PE>>1)-1-i]),
            .B_dat(accu_l1_r[(NUM_PE>>1)-1-i]),
            .B_rdy(),
            .S_vld(accu_l2_vld[i]),
            .S_dat(accu_l2[i]),
            .S_rdy(1'b1),
            .overflow()
        ); // sif_add
    end

    for(i=0; i<(NUM_PE>>2); i=i+1)
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
end
endgenerate


// =========================================================================== //
// The third-lever adder in adder tree for the accumulation of mul results
// =========================================================================== //
generate
if (pc>16) begin : SELECT_THIRD_LEVEL_ADDER
    for(i=0; i<(NUM_PE>>3) ; i=i+1)
    begin : THIRD_LEVEL_ADDER
        sif_add #(
            .WIDTH_A(2*in_data_width+$clog2(pe)+2),
            .WIDTH_B(2*in_data_width+$clog2(pe)+2),
            .WIDTH_S(2*in_data_width+$clog2(pe)+3),
            .TYPE_SIGNAL(0),
            .TYPE_OP(0)
        ) u_sif_add_result_3rd
        (
            .rst_n(rst_n),
            .clk(clk),
            .A_vld(accu_l2_vld_r[i]),
            .A_dat(accu_l2_r[i]),
            .A_rdy(),
            .B_vld(accu_l2_vld_r[(NUM_PE>>2)-1-i]),
            .B_dat(accu_l2_r[(NUM_PE>>2)-1-i]),
            .B_rdy(),
            .S_vld(accu_l3_vld[i]),
            .S_dat(accu_l3[i]),
            .S_rdy(1'b1),
            .overflow()
        ); // sif_add
    end

    for(i=0; i<(NUM_PE>>3); i=i+1)
    begin : GENERATE_ACCU_REG_THIRD_LEVEL
        always @(posedge clk or negedge rst_n)
        if(!rst_n) begin
            accu_l3_r[i] <= 0;
            accu_l3_vld_r[i] <= 0; 
        end
        else if(accu_l3_vld[i]) begin
            accu_l3_r[i] <= accu_l3[i];
            accu_l3_vld_r[i] <= accu_l3_vld[i];
        end
        else begin
            accu_l3_r[i] <= 0;
            accu_l3_vld_r[i] <= 0; 
        end
    end   
end
endgenerate

// =========================================================================== //
// The forth-lever adder in adder tree for the accumulation of mul results
// =========================================================================== //
generate
if (pc>32) begin : SELECT_FOURTH_LEVEL_ADDER
    for(i=0; i<(NUM_PE>>4) ; i=i+1)
    begin : FOURTH_LEVEL_ADDER
        sif_add #(
            .WIDTH_A(2*in_data_width+$clog2(pe)+3),
            .WIDTH_B(2*in_data_width+$clog2(pe)+3),
            .WIDTH_S(2*in_data_width+$clog2(pe)+4),
            .TYPE_SIGNAL(0),
            .TYPE_OP(0)
        ) u_sif_add_result_4th
        (
            .rst_n(rst_n),
            .clk(clk),
            .A_vld(accu_l3_vld_r[i]),
            .A_dat(accu_l3_r[i]),
            .A_rdy(),
            .B_vld(accu_l3_vld_r[(NUM_PE>>3)-1-i]),
            .B_dat(accu_l3_r[(NUM_PE>>3)-1-i]),
            .B_rdy(),
            .S_vld(accu_l4_vld[i]),
            .S_dat(accu_l4[i]),
            .S_rdy(1'b1),
            .overflow()
        ); // sif_add
    end

    for(i=0; i<(NUM_PE>>4); i=i+1)
    begin : GENERATE_ACCU_REG_FORTH_LEVEL
        always @(posedge clk or negedge rst_n)
        if(!rst_n) begin
            accu_l4_r[i] <= 0;
            accu_l4_vld_r[i] <= 0; 
        end
        else if(accu_l4_vld[i]) begin
            accu_l4_r[i] <= accu_l4[i];
            accu_l4_vld_r[i] <= accu_l4_vld[i];
        end
        else begin
            accu_l4_r[i] <= 0;
            accu_l4_vld_r[i] <= 0; 
        end
    end
end
endgenerate

// =========================================================================== //
// The fifth-lever adder in adder tree for the accumulation of mul results
// =========================================================================== //
generate
if (pc>64) begin : SELECT_FIFTH_LEVEL_ADDER
    for(i=0; i<(NUM_PE>>5) ; i=i+1)
    begin : FIFTH_LEVEL_ADDER
        sif_add #(
            .WIDTH_A(2*in_data_width+$clog2(pe)+4),
            .WIDTH_B(2*in_data_width+$clog2(pe)+4),
            .WIDTH_S(2*in_data_width+$clog2(pe)+5),
            .TYPE_SIGNAL(0),
            .TYPE_OP(0)
        ) u_sif_add_result_4th
        (
            .rst_n(rst_n),
            .clk(clk),
            .A_vld(accu_l4_vld_r[i]),
            .A_dat(accu_l4_r[i]),
            .A_rdy(),
            .B_vld(accu_l4_vld_r[(NUM_PE>>4)-1-i]),
            .B_dat(accu_l4_r[(NUM_PE>>4)-1-i]),
            .B_rdy(),
            .S_vld(accu_l5_vld[i]),
            .S_dat(accu_l5[i]),
            .S_rdy(1'b1),
            .overflow()
        ); // sif_add
    end

    for(i=0; i<(NUM_PE>>5); i=i+1)
    begin : GENERATE_ACCU_REG_FIFTH_LEVEL
        always @(posedge clk or negedge rst_n)
        if(!rst_n) begin
            accu_l5_r[i] <= 0;
            accu_l5_vld_r[i] <= 0; 
        end
        else if(accu_l5_vld[i]) begin
            accu_l5_r[i] <= accu_l5[i];
            accu_l5_vld_r[i] <= accu_l5_vld[i];
        end
        else begin
            accu_l5_r[i] <= 0;
            accu_l5_vld_r[i] <= 0; 
        end
    end
end
endgenerate


// =========================================================================== //
// Accumulator to sum the result from different channel and position
// =========================================================================== //

// Turn on first_dat_point if the last acc_result_vld_r is valid, turn off if the first_dat_point is inputed into adder
always @(posedge clk or negedge rst_n)
if(!rst_n) 
    first_dat_point <= 1'b0; 
else if(acc_result_vld_r[LATENCY_CU-2]) begin
    first_dat_point <= 1'b1;
end
else begin
    if (partial_result_vld)
        first_dat_point <= 1'b0;
    else
        first_dat_point <= first_dat_point;
end

generate
if (pc==8) begin
    assign partial_result_vld = accu_l1_vld_r[0];
    assign partial_result = (accu_l1_vld_r[0] & ((!acc_result_vld_r[LATENCY_CU-1]) & !first_dat_point)) ? accu_chnl : {out_data_width{1'b0}};
    sif_add #(
        .WIDTH_B(2*in_data_width+$clog2(pe)+1),
        .WIDTH_A(out_data_width),
        .WIDTH_S(out_data_width),
        .TYPE_SIGNAL(1),
        .TYPE_OP(0)
    ) u_sif_acc_chnl_pos
    (
        .rst_n(rst_n),
        .clk(clk),
        .B_vld(accu_l1_vld_r[0]),
        .B_dat(accu_l1_r[0]),
        .B_rdy(),
        .A_vld(partial_result_vld),
        .A_dat(partial_result),
        .A_rdy(),
        .S_vld(accu_chnl_vld),
        .S_dat(accu_chnl),
        .S_rdy(1'b1),
        .overflow()
    ); // sif_add
end
else if (pc==16) begin
    assign partial_result_vld = accu_l2_vld_r[0];
    assign partial_result = (accu_l2_vld_r[0] & ((!acc_result_vld_r[LATENCY_CU-1]) & !first_dat_point)) ? accu_chnl : {out_data_width{1'b0}};
    sif_add #(
        .WIDTH_B(2*in_data_width+$clog2(pe)+2),
        .WIDTH_A(out_data_width),
        .WIDTH_S(out_data_width),
        .TYPE_SIGNAL(1),
        .TYPE_OP(0)
    ) u_sif_acc_chnl_pos
    (
        .rst_n(rst_n),
        .clk(clk),
        .B_vld(accu_l2_vld_r[0]),
        .B_dat(accu_l2_r[0]),
        .B_rdy(),
        .A_vld(partial_result_vld),
        .A_dat(partial_result),
        .A_rdy(),
        .S_vld(accu_chnl_vld),
        .S_dat(accu_chnl),
        .S_rdy(1'b1),
        .overflow()
    ); // sif_add
end
else if (pc==32) begin
    assign partial_result_vld = accu_l3_vld_r[0];
    assign partial_result = (accu_l3_vld_r[0] & ((!acc_result_vld_r[LATENCY_CU-1]) & !first_dat_point)) ? accu_chnl : {out_data_width{1'b0}};
    sif_add #(
        .WIDTH_B(2*in_data_width+$clog2(pe)+3),
        .WIDTH_A(out_data_width),
        .WIDTH_S(out_data_width),
        .TYPE_SIGNAL(1),
        .TYPE_OP(0)
    ) u_sif_acc_chnl_pos
    (
        .rst_n(rst_n),
        .clk(clk),
        .B_vld(accu_l3_vld_r[0]),
        .B_dat(accu_l3_r[0]),
        .B_rdy(),
        .A_vld(partial_result_vld),
        .A_dat(partial_result),
        .A_rdy(),
        .S_vld(accu_chnl_vld),
        .S_dat(accu_chnl),
        .S_rdy(1'b1),
        .overflow()
    ); // sif_add
end 
else if (pc==64) begin
    assign partial_result_vld = accu_l4_vld_r[0];
    assign partial_result = (accu_l4_vld_r[0] & ((!acc_result_vld_r[LATENCY_CU-1]) & !first_dat_point)) ? accu_chnl : {out_data_width{1'b0}};
    sif_add #(
        .WIDTH_B(2*in_data_width+$clog2(pe)+4),
        .WIDTH_A(out_data_width),
        .WIDTH_S(out_data_width),
        .TYPE_SIGNAL(1),
        .TYPE_OP(0)
    ) u_sif_acc_chnl_pos
    (
        .rst_n(rst_n),
        .clk(clk),
        .B_vld(accu_l4_vld_r[0]),
        .B_dat(accu_l4_r[0]),
        .B_rdy(),
        .A_vld(partial_result_vld),
        .A_dat(partial_result),
        .A_rdy(),
        .S_vld(accu_chnl_vld),
        .S_dat(accu_chnl),
        .S_rdy(1'b1),
        .overflow()
    ); // sif_add
end
else if (pc==128) begin
    assign partial_result_vld = accu_l5_vld_r[0];
    assign partial_result = (accu_l5_vld_r[0] & ((!acc_result_vld_r[LATENCY_CU-1]) & !first_dat_point)) ? accu_chnl : {out_data_width{1'b0}};
    sif_add #(
        .WIDTH_B(2*in_data_width+$clog2(pe)+5),
        .WIDTH_A(out_data_width),
        .WIDTH_S(out_data_width),
        .TYPE_SIGNAL(1),
        .TYPE_OP(0)
    ) u_sif_acc_chnl_pos
    (
        .rst_n(rst_n),
        .clk(clk),
        .B_vld(accu_l5_vld_r[0]),
        .B_dat(accu_l5_r[0]),
        .B_rdy(),
        .A_vld(partial_result_vld),
        .A_dat(partial_result),
        .A_rdy(),
        .S_vld(accu_chnl_vld),
        .S_dat(accu_chnl),
        .S_rdy(1'b1),
        .overflow()
    ); // sif_add
end
endgenerate


// =========================================================================== //
// Generate the finish signal which indicates the result of 
//   compute unit is valid
// =========================================================================== //
always @(posedge clk or negedge rst_n)
if(!rst_n) 
    acc_result_vld_r[0] <= 0; 
  else if(acc_result_vld&up_vld&coef_vld) // Needs improvement 
    acc_result_vld_r[0] <= acc_result_vld;
else 
    acc_result_vld_r[0] <= 0;

generate
for(i=1; i<LATENCY_CU; i=i+1)
begin : GENERATE_ACC_VALID
    always @(posedge clk or negedge rst_n)
    if(!rst_n) 
        acc_result_vld_r[i] <= 0; 
    else if(acc_result_vld_r[i-1]) // Needs improvement 
        acc_result_vld_r[i] <= acc_result_vld_r[i-1];
    else 
        acc_result_vld_r[i] <= 0;
end
endgenerate


// =========================================================================== //
// Generate the filter finish signal indicates the computation of cu+bias completed
// =========================================================================== //
always @(posedge clk or negedge rst_n)
if(!rst_n) 
    filter_finish_data_r[0] <= 0; 
else if(filter_finish_data & dn_rdy & coef_vld) // Needs improvement 
    filter_finish_data_r[0] <= filter_finish_data;
else 
    filter_finish_data_r[0] <= 0;

generate
for(i=1; i<LATENCY_CU_BIAS; i=i+1)
begin : GENERATE_FILTER_VALID
    always @(posedge clk or negedge rst_n)
    if(!rst_n) 
        filter_finish_data_r[i] <= 0; 
    else if(filter_finish_data_r[i-1]) // Needs improvement 
        filter_finish_data_r[i] <= filter_finish_data_r[i-1];
    else 
        filter_finish_data_r[i] <= 0;
end
endgenerate

always @(posedge clk or negedge rst_n)
if(!rst_n) 
    filter_finish_cal_r <= 0; 
else if(filter_finish_data_r[LATENCY_CU_BIAS-2]) // Update before the bias add, bugs in conv1*1
    filter_finish_cal_r <= 1;
else 
    filter_finish_cal_r <= 0;

assign filter_finish_cal = filter_finish_cal_r;

// =========================================================================== //
// The result will output to bias adder only if the acc_result_vld is 1 
// =========================================================================== //
always @(posedge clk or negedge rst_n)
if(!rst_n) begin
    accu_chnl_r <= 0;
    accu_chnl_vld_r <= 0; 
end
else if(accu_chnl_vld & acc_result_vld_r[LATENCY_CU-1]) begin
    accu_chnl_r <= accu_chnl;
    accu_chnl_vld_r <= accu_chnl_vld;
end
else begin
    accu_chnl_r <= 0;
    accu_chnl_vld_r <= 0; 
end


// =========================================================================== //
// The bias module which adds the bias with accumulated channel result 
// =========================================================================== //
sif_add #(
    .WIDTH_A(out_data_width),
    .WIDTH_B(bias_data_width),
    .WIDTH_S(out_data_width),
    .TYPE_SIGNAL(1),
    .TYPE_OP(0)
) u_sif_bias_add_pos
(
    .rst_n(rst_n),
    .clk(clk),
    .A_vld(accu_chnl_vld_r),
    .A_dat(accu_chnl_r),
    .A_rdy(),
    .B_vld(bias_vld),
    .B_dat(bias_dat),
    .B_rdy(),
    .S_vld(bias_result_vld),
    .S_dat(bias_result_dat),
    .S_rdy(1'b1),
    .overflow()
); // sif_add


barrel_shifter #(
    .w(bias_data_width)
)
u_barrel_shifter (
    .rst_n(rst_n),
    .clk(clk),  
    .up_dat(bias_result_dat),
    .dn_dat(shifted_dat),
    .ctrl(shift_bits)  
);

assign dn_vld = bias_result_vld;
assign dn_dat = {shifted_dat[31], shifted_dat[16:10]}; // one sign bit, one leading bit, 6 fraction bit

endmodule