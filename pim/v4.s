	.file	"bench_gemv.c"
	.text
	.globl	pim_mxfp4_gemv_opt              // -- Begin function pim_mxfp4_gemv_opt
	.p2align	4
	.type	pim_mxfp4_gemv_opt,@function
pim_mxfp4_gemv_opt:                     // @pim_mxfp4_gemv_opt
	.cfi_startproc
// %bb.0:
	sub	sp, sp, #304
	.cfi_def_cfa_offset 304
	str	x30, [sp, #208]                 // 8-byte Folded Spill
	stp	x28, x27, [sp, #224]            // 16-byte Folded Spill
	stp	x26, x25, [sp, #240]            // 16-byte Folded Spill
	stp	x24, x23, [sp, #256]            // 16-byte Folded Spill
	stp	x22, x21, [sp, #272]            // 16-byte Folded Spill
	stp	x20, x19, [sp, #288]            // 16-byte Folded Spill
	.cfi_offset w19, -8
	.cfi_offset w20, -16
	.cfi_offset w21, -24
	.cfi_offset w22, -32
	.cfi_offset w23, -40
	.cfi_offset w24, -48
	.cfi_offset w25, -56
	.cfi_offset w26, -64
	.cfi_offset w27, -72
	.cfi_offset w28, -80
	.cfi_offset w30, -96
	.cfi_remember_state
	cmp	w5, #1
                                        // kill: def $w6 killed $w6 def $x6
	stp	x3, x0, [sp, #120]              // 16-byte Folded Spill
	str	x2, [sp, #136]                  // 8-byte Folded Spill
	str	x1, [sp, #80]                   // 8-byte Folded Spill
	b.lt	.LBB0_74
// %bb.1:
	add	w8, w4, w6
	mov	w0, w5
	sub	w8, w8, #1
	sdiv	w1, w8, w6
	cmp	w1, #0
	b.le	.LBB0_75
// %bb.2:
	add	w9, w4, w4, lsr #31
	add	w8, w6, w6, lsr #31
	sbfx	x3, x9, #1, #31
	sxtw	x9, w1
	sxtw	x14, w6
	ldr	x10, [sp, #80]                  // 8-byte Folded Reload
	mov	x2, xzr
	lsl	x19, x14, #4
	str	x9, [sp, #88]                   // 8-byte Folded Spill
	sbfx	x9, x8, #1, #31
	and	x8, x1, #0x3
	add	x12, x10, #8
	lsl	x5, x9, #2
	adrp	x23, PIM_E2M1
	add	x23, x23, :lo12:PIM_E2M1
	str	x8, [sp, #144]                  // 8-byte Folded Spill
	and	x8, x1, #0x7ffffffc
	str	x12, [sp, #72]                  // 8-byte Folded Spill
	stp	x8, x9, [sp, #192]              // 16-byte Folded Spill
	ldr	x8, [sp, #136]                  // 8-byte Folded Reload
	add	x11, x8, #1
	lsl	x8, x14, #2
	add	x15, x12, x8
	add	x13, x11, x9
	str	x8, [sp, #16]                   // 8-byte Folded Spill
	add	x8, x10, x8
	stp	x13, x11, [sp, #176]            // 16-byte Folded Spill
	stp	x8, x15, [sp, #56]              // 16-byte Folded Spill
	lsl	x8, x9, #1
	lsl	x9, x14, #3
	add	x24, x11, x8
	add	x11, x12, x9
	add	x9, x10, x9
	add	x27, x13, x8
	stp	x9, x11, [sp, #40]              // 16-byte Folded Spill
	add	x9, x14, x14, lsl #1
	lsl	x8, x9, #2
	add	x9, x12, x8
	add	x8, x10, x8
	stp	x8, x9, [sp, #24]               // 16-byte Folded Spill
	adrp	x21, :got:PIM_E2M1_PAIR
	ldr	x21, [x21, :got_lo12:PIM_E2M1_PAIR]
	adrp	x25, :got:PIM_E8M0
	ldr	x25, [x25, :got_lo12:PIM_E8M0]
	stp	x1, x0, [sp, #104]              // 16-byte Folded Spill
	str	x3, [sp, #96]                   // 8-byte Folded Spill
	b	.LBB0_5
.LBB0_3:                                //   in Loop: Header=BB0_5 Depth=1
	fadd	s1, s2, s1
	fadd	s2, s3, s4
	fadd	s1, s2, s1
	fadd	s0, s0, s1
	ldr	s1, [x25, x8, lsl #2]
	fmul	s0, s0, s1
	.p2align	4, , 8
.LBB0_4:                                //   in Loop: Header=BB0_5 Depth=1
	ldr	x8, [sp, #128]                  // 8-byte Folded Reload
	add	x24, x24, x3
	add	x27, x27, x3
	str	s0, [x8, x2, lsl #2]
	ldr	x8, [sp, #184]                  // 8-byte Folded Reload
	add	x2, x2, #1
	cmp	x2, x0
	add	x8, x8, x3
	str	x8, [sp, #184]                  // 8-byte Folded Spill
	ldr	x8, [sp, #176]                  // 8-byte Folded Reload
	add	x8, x8, x3
	str	x8, [sp, #176]                  // 8-byte Folded Spill
	b.eq	.LBB0_74
.LBB0_5:                                // =>This Loop Header: Depth=1
                                        //     Child Loop BB0_16 Depth 2
                                        //       Child Loop BB0_19 Depth 3
                                        //       Child Loop BB0_23 Depth 3
                                        //       Child Loop BB0_28 Depth 3
                                        //       Child Loop BB0_32 Depth 3
                                        //       Child Loop BB0_37 Depth 3
                                        //       Child Loop BB0_41 Depth 3
                                        //       Child Loop BB0_46 Depth 3
                                        //       Child Loop BB0_50 Depth 3
                                        //     Child Loop BB0_11 Depth 2
                                        //     Child Loop BB0_53 Depth 2
                                        //     Child Loop BB0_59 Depth 2
                                        //     Child Loop BB0_63 Depth 2
                                        //     Child Loop BB0_69 Depth 2
                                        //     Child Loop BB0_73 Depth 2
	ldr	x10, [sp, #136]                 // 8-byte Folded Reload
	mul	x8, x2, x3
	ldr	x9, [sp, #88]                   // 8-byte Folded Reload
	cmp	w1, #4
	stp	x24, x2, [sp, #160]             // 16-byte Folded Spill
	add	x8, x10, x8
	str	x27, [sp, #152]                 // 8-byte Folded Spill
	mul	x9, x2, x9
	str	x8, [sp, #216]                  // 8-byte Folded Spill
	ldr	x8, [sp, #120]                  // 8-byte Folded Reload
	add	x26, x8, x9
	b.hs	.LBB0_13
// %bb.6:                               //   in Loop: Header=BB0_5 Depth=1
	movi	d0, #0000000000000000
	mov	x28, xzr
.LBB0_7:                                //   in Loop: Header=BB0_5 Depth=1
	ldp	x1, x0, [sp, #104]              // 16-byte Folded Reload
	ldp	x24, x2, [sp, #160]             // 16-byte Folded Reload
	ldp	x8, x27, [sp, #144]             // 16-byte Folded Reload
	ldr	x3, [sp, #96]                   // 8-byte Folded Reload
	cbz	x8, .LBB0_4
// %bb.8:                               //   in Loop: Header=BB0_5 Depth=1
	ldrb	w8, [x26, x28]
	cmp	x8, #255
	b.eq	.LBB0_55
// %bb.9:                               //   in Loop: Header=BB0_5 Depth=1
	mul	x11, x28, x14
	ldr	x10, [sp, #200]                 // 8-byte Folded Reload
	sub	w9, w4, w11
	mul	x12, x28, x10
	cmp	w9, w6
	csel	w9, w9, w6, lt
	cmp	w9, #4
	b.lt	.LBB0_51
// %bb.10:                              //   in Loop: Header=BB0_5 Depth=1
	ldr	x10, [sp, #72]                  // 8-byte Folded Reload
	movi	d1, #0000000000000000
	ldr	x13, [sp, #16]                  // 8-byte Folded Reload
	movi	d4, #0000000000000000
	movi	d3, #0000000000000000
	movi	d2, #0000000000000000
	mov	x15, xzr
	madd	x17, x13, x28, x10
	ldr	x10, [sp, #184]                 // 8-byte Folded Reload
	add	x10, x10, x12
	.p2align	4, , 8
.LBB0_11:                               //   Parent Loop BB0_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldurb	w13, [x10, #-1]
	ldrb	w16, [x10], #2
	ldp	s5, s6, [x17, #-8]
	add	x13, x21, x13, lsl #3
	add	x16, x21, x16, lsl #3
	ldp	s19, s20, [x17], #16
	ldp	s7, s16, [x13]
	ldp	s17, s18, [x16]
	add	x13, x15, #7
	add	x15, x15, #4
	cmp	x13, x9
	fmadd	s1, s7, s5, s1
	fmadd	s2, s16, s6, s2
	fmadd	s3, s17, s19, s3
	fmadd	s4, s18, s20, s4
	b.lo	.LBB0_11
// %bb.12:                              //   in Loop: Header=BB0_5 Depth=1
	mov	w10, w15
	cmp	w10, w9
	b.lt	.LBB0_52
	b	.LBB0_54
	.p2align	4, , 8
.LBB0_13:                               //   in Loop: Header=BB0_5 Depth=1
	ldp	x30, x7, [sp, #24]              // 16-byte Folded Reload
	movi	d0, #0000000000000000
	mov	x28, xzr
	ldp	x8, x1, [sp, #40]               // 16-byte Folded Reload
	ldp	x3, x16, [sp, #56]              // 16-byte Folded Reload
	ldp	x13, x17, [sp, #176]            // 16-byte Folded Reload
	ldp	x11, x15, [sp, #72]             // 16-byte Folded Reload
	b	.LBB0_16
	.p2align	4, , 8
.LBB0_14:                               //   in Loop: Header=BB0_16 Depth=2
	fadd	s1, s2, s1
	fadd	s2, s3, s4
	fadd	s1, s2, s1
	fadd	s0, s0, s1
	ldr	s1, [x25, x9, lsl #2]
	fmul	s0, s0, s1
.LBB0_15:                               //   in Loop: Header=BB0_16 Depth=2
	ldr	x9, [sp, #192]                  // 8-byte Folded Reload
	add	x28, x28, #4
	add	x17, x17, x5
	add	x11, x11, x19
	add	x15, x15, x19
	add	x13, x13, x5
	add	x16, x16, x19
	add	x3, x3, x19
	add	x24, x24, x5
	add	x1, x1, x19
	add	x8, x8, x19
	add	x27, x27, x5
	add	x7, x7, x19
	add	x30, x30, x19
	cmp	x28, x9
	b.eq	.LBB0_7
.LBB0_16:                               //   Parent Loop BB0_5 Depth=1
                                        // =>  This Loop Header: Depth=2
                                        //       Child Loop BB0_19 Depth 3
                                        //       Child Loop BB0_23 Depth 3
                                        //       Child Loop BB0_28 Depth 3
                                        //       Child Loop BB0_32 Depth 3
                                        //       Child Loop BB0_37 Depth 3
                                        //       Child Loop BB0_41 Depth 3
                                        //       Child Loop BB0_46 Depth 3
                                        //       Child Loop BB0_50 Depth 3
	ldrb	w9, [x26, x28]
	cmp	x9, #255
	b.eq	.LBB0_25
// %bb.17:                              //   in Loop: Header=BB0_16 Depth=2
	msub	w10, w28, w14, w4
	cmp	w10, w6
	csel	w12, w10, w6, lt
	cmp	w12, #4
	b.lt	.LBB0_21
// %bb.18:                              //   in Loop: Header=BB0_16 Depth=2
	movi	d1, #0000000000000000
	movi	d4, #0000000000000000
	movi	d3, #0000000000000000
	movi	d2, #0000000000000000
	mov	x10, x11
	mov	x2, x17
	mov	w0, #3                          // =0x3
	.p2align	4, , 8
.LBB0_19:                               //   Parent Loop BB0_5 Depth=1
                                        //     Parent Loop BB0_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldurb	w20, [x2, #-1]
	add	x0, x0, #4
	ldrb	w22, [x2], #2
	ldp	s5, s6, [x10, #-8]
	add	x20, x21, x20, lsl #3
	cmp	x0, x12
	add	x22, x21, x22, lsl #3
	ldp	s19, s20, [x10], #16
	ldp	s7, s16, [x20]
	ldp	s17, s18, [x22]
	fmadd	s1, s7, s5, s1
	fmadd	s2, s16, s6, s2
	fmadd	s3, s17, s19, s3
	fmadd	s4, s18, s20, s4
	b.lo	.LBB0_19
// %bb.20:                              //   in Loop: Header=BB0_16 Depth=2
	sub	w10, w0, #3
	cmp	w10, w12
	b.lt	.LBB0_22
	b	.LBB0_24
	.p2align	4, , 8
.LBB0_21:                               //   in Loop: Header=BB0_16 Depth=2
	movi	d2, #0000000000000000
	movi	d3, #0000000000000000
	movi	d4, #0000000000000000
	movi	d1, #0000000000000000
	mov	x10, xzr
	cmp	w10, w12
	b.ge	.LBB0_24
.LBB0_22:                               //   in Loop: Header=BB0_16 Depth=2
	ldr	x0, [sp, #200]                  // 8-byte Folded Reload
	ldr	x2, [sp, #216]                  // 8-byte Folded Reload
	mul	x0, x28, x0
	add	x0, x2, x0
	.p2align	4, , 8
.LBB0_23:                               //   Parent Loop BB0_5 Depth=1
                                        //     Parent Loop BB0_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	lsr	w2, w10, #1
	tst	x10, #0x1
	ldr	s6, [x15, x10, lsl #2]
	add	x10, x10, #1
	ldrb	w2, [x0, x2]
	lsr	w20, w2, #4
	and	w2, w2, #0xf
	csel	w2, w2, w20, eq
	cmp	x10, x12
	ldr	s5, [x23, w2, uxtw #2]
	fmadd	s1, s5, s6, s1
	b.lo	.LBB0_23
.LBB0_24:                               //   in Loop: Header=BB0_16 Depth=2
	fadd	s1, s2, s1
	fadd	s2, s3, s4
	fadd	s1, s2, s1
	fadd	s0, s0, s1
	ldr	s1, [x25, x9, lsl #2]
	fmul	s0, s0, s1
.LBB0_25:                               //   in Loop: Header=BB0_16 Depth=2
	orr	x2, x28, #0x1
	ldrb	w9, [x26, x2]
	cmp	x9, #255
	b.eq	.LBB0_34
// %bb.26:                              //   in Loop: Header=BB0_16 Depth=2
	msub	w10, w2, w14, w4
	cmp	w10, w6
	csel	w12, w10, w6, lt
	cmp	w12, #4
	b.lt	.LBB0_30
// %bb.27:                              //   in Loop: Header=BB0_16 Depth=2
	movi	d1, #0000000000000000
	movi	d4, #0000000000000000
	movi	d3, #0000000000000000
	movi	d2, #0000000000000000
	mov	x10, xzr
	mov	x0, x16
	mov	x20, x13
	.p2align	4, , 8
.LBB0_28:                               //   Parent Loop BB0_5 Depth=1
                                        //     Parent Loop BB0_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldurb	w22, [x20, #-1]
	ldrb	w25, [x20], #2
	ldp	s5, s6, [x0, #-8]
	add	x22, x21, x22, lsl #3
	add	x25, x21, x25, lsl #3
	ldp	s19, s20, [x0], #16
	ldp	s7, s16, [x22]
	ldp	s17, s18, [x25]
	add	x22, x10, #7
	add	x10, x10, #4
	cmp	x22, x12
	fmadd	s1, s7, s5, s1
	fmadd	s2, s16, s6, s2
	fmadd	s3, s17, s19, s3
	fmadd	s4, s18, s20, s4
	b.lo	.LBB0_28
// %bb.29:                              //   in Loop: Header=BB0_16 Depth=2
	mov	w10, w10
	adrp	x25, :got:PIM_E8M0
	ldr	x25, [x25, :got_lo12:PIM_E8M0]
	cmp	w10, w12
	b.lt	.LBB0_31
	b	.LBB0_33
	.p2align	4, , 8
.LBB0_30:                               //   in Loop: Header=BB0_16 Depth=2
	movi	d2, #0000000000000000
	movi	d3, #0000000000000000
	movi	d4, #0000000000000000
	movi	d1, #0000000000000000
	mov	x10, xzr
	cmp	w10, w12
	b.ge	.LBB0_33
.LBB0_31:                               //   in Loop: Header=BB0_16 Depth=2
	ldr	x0, [sp, #200]                  // 8-byte Folded Reload
	ldr	x20, [sp, #216]                 // 8-byte Folded Reload
	nop
	madd	x0, x2, x0, x20
	.p2align	4, , 8
.LBB0_32:                               //   Parent Loop BB0_5 Depth=1
                                        //     Parent Loop BB0_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	lsr	w2, w10, #1
	tst	x10, #0x1
	ldr	s6, [x3, x10, lsl #2]
	add	x10, x10, #1
	ldrb	w2, [x0, x2]
	lsr	w20, w2, #4
	and	w2, w2, #0xf
	csel	w2, w2, w20, eq
	cmp	x10, x12
	ldr	s5, [x23, w2, uxtw #2]
	fmadd	s1, s5, s6, s1
	b.lo	.LBB0_32
.LBB0_33:                               //   in Loop: Header=BB0_16 Depth=2
	fadd	s1, s2, s1
	fadd	s2, s3, s4
	fadd	s1, s2, s1
	fadd	s0, s0, s1
	ldr	s1, [x25, x9, lsl #2]
	fmul	s0, s0, s1
.LBB0_34:                               //   in Loop: Header=BB0_16 Depth=2
	orr	x2, x28, #0x2
	ldrb	w9, [x26, x2]
	cmp	x9, #255
	b.eq	.LBB0_43
// %bb.35:                              //   in Loop: Header=BB0_16 Depth=2
	msub	w10, w2, w14, w4
	cmp	w10, w6
	csel	w12, w10, w6, lt
	cmp	w12, #4
	b.lt	.LBB0_39
// %bb.36:                              //   in Loop: Header=BB0_16 Depth=2
	movi	d1, #0000000000000000
	movi	d4, #0000000000000000
	movi	d3, #0000000000000000
	movi	d2, #0000000000000000
	mov	x10, xzr
	mov	x0, x1
	mov	x20, x24
	.p2align	4, , 8
.LBB0_37:                               //   Parent Loop BB0_5 Depth=1
                                        //     Parent Loop BB0_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldurb	w22, [x20, #-1]
	ldrb	w25, [x20], #2
	ldp	s5, s6, [x0, #-8]
	add	x22, x21, x22, lsl #3
	add	x25, x21, x25, lsl #3
	ldp	s19, s20, [x0], #16
	ldp	s7, s16, [x22]
	ldp	s17, s18, [x25]
	add	x22, x10, #7
	add	x10, x10, #4
	cmp	x22, x12
	fmadd	s1, s7, s5, s1
	fmadd	s2, s16, s6, s2
	fmadd	s3, s17, s19, s3
	fmadd	s4, s18, s20, s4
	b.lo	.LBB0_37
// %bb.38:                              //   in Loop: Header=BB0_16 Depth=2
	mov	w10, w10
	adrp	x25, :got:PIM_E8M0
	ldr	x25, [x25, :got_lo12:PIM_E8M0]
	cmp	w10, w12
	b.lt	.LBB0_40
	b	.LBB0_42
	.p2align	4, , 8
.LBB0_39:                               //   in Loop: Header=BB0_16 Depth=2
	movi	d2, #0000000000000000
	movi	d3, #0000000000000000
	movi	d4, #0000000000000000
	movi	d1, #0000000000000000
	mov	x10, xzr
	cmp	w10, w12
	b.ge	.LBB0_42
.LBB0_40:                               //   in Loop: Header=BB0_16 Depth=2
	ldr	x0, [sp, #200]                  // 8-byte Folded Reload
	ldr	x20, [sp, #216]                 // 8-byte Folded Reload
	nop
	madd	x0, x2, x0, x20
	.p2align	4, , 8
.LBB0_41:                               //   Parent Loop BB0_5 Depth=1
                                        //     Parent Loop BB0_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	lsr	w2, w10, #1
	tst	x10, #0x1
	ldr	s6, [x8, x10, lsl #2]
	add	x10, x10, #1
	ldrb	w2, [x0, x2]
	lsr	w20, w2, #4
	and	w2, w2, #0xf
	csel	w2, w2, w20, eq
	cmp	x10, x12
	ldr	s5, [x23, w2, uxtw #2]
	fmadd	s1, s5, s6, s1
	b.lo	.LBB0_41
.LBB0_42:                               //   in Loop: Header=BB0_16 Depth=2
	fadd	s1, s2, s1
	fadd	s2, s3, s4
	fadd	s1, s2, s1
	fadd	s0, s0, s1
	ldr	s1, [x25, x9, lsl #2]
	fmul	s0, s0, s1
.LBB0_43:                               //   in Loop: Header=BB0_16 Depth=2
	orr	x2, x28, #0x3
	ldrb	w9, [x26, x2]
	cmp	x9, #255
	b.eq	.LBB0_15
// %bb.44:                              //   in Loop: Header=BB0_16 Depth=2
	msub	w10, w2, w14, w4
	cmp	w10, w6
	csel	w12, w10, w6, lt
	cmp	w12, #4
	b.lt	.LBB0_48
// %bb.45:                              //   in Loop: Header=BB0_16 Depth=2
	movi	d1, #0000000000000000
	movi	d4, #0000000000000000
	movi	d3, #0000000000000000
	movi	d2, #0000000000000000
	mov	x10, xzr
	mov	x0, x7
	mov	x20, x27
	.p2align	4, , 8
.LBB0_46:                               //   Parent Loop BB0_5 Depth=1
                                        //     Parent Loop BB0_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldurb	w22, [x20, #-1]
	ldrb	w25, [x20], #2
	ldp	s5, s6, [x0, #-8]
	add	x22, x21, x22, lsl #3
	add	x25, x21, x25, lsl #3
	ldp	s19, s20, [x0], #16
	ldp	s7, s16, [x22]
	ldp	s17, s18, [x25]
	add	x22, x10, #7
	add	x10, x10, #4
	cmp	x22, x12
	fmadd	s1, s7, s5, s1
	fmadd	s2, s16, s6, s2
	fmadd	s3, s17, s19, s3
	fmadd	s4, s18, s20, s4
	b.lo	.LBB0_46
// %bb.47:                              //   in Loop: Header=BB0_16 Depth=2
	mov	w10, w10
	adrp	x25, :got:PIM_E8M0
	ldr	x25, [x25, :got_lo12:PIM_E8M0]
	cmp	w10, w12
	b.ge	.LBB0_14
	b	.LBB0_49
	.p2align	4, , 8
.LBB0_48:                               //   in Loop: Header=BB0_16 Depth=2
	movi	d2, #0000000000000000
	movi	d3, #0000000000000000
	movi	d4, #0000000000000000
	movi	d1, #0000000000000000
	mov	x10, xzr
	cmp	w10, w12
	b.ge	.LBB0_14
.LBB0_49:                               //   in Loop: Header=BB0_16 Depth=2
	ldr	x0, [sp, #200]                  // 8-byte Folded Reload
	ldr	x20, [sp, #216]                 // 8-byte Folded Reload
	nop
	madd	x0, x2, x0, x20
	.p2align	4, , 8
.LBB0_50:                               //   Parent Loop BB0_5 Depth=1
                                        //     Parent Loop BB0_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	lsr	w2, w10, #1
	tst	x10, #0x1
	ldr	s6, [x30, x10, lsl #2]
	add	x10, x10, #1
	ldrb	w2, [x0, x2]
	lsr	w20, w2, #4
	and	w2, w2, #0xf
	csel	w2, w2, w20, eq
	cmp	x10, x12
	ldr	s5, [x23, w2, uxtw #2]
	fmadd	s1, s5, s6, s1
	b.lo	.LBB0_50
	b	.LBB0_14
.LBB0_51:                               //   in Loop: Header=BB0_5 Depth=1
	movi	d2, #0000000000000000
	movi	d3, #0000000000000000
	movi	d4, #0000000000000000
	movi	d1, #0000000000000000
	mov	x10, xzr
	cmp	w10, w9
	b.ge	.LBB0_54
.LBB0_52:                               //   in Loop: Header=BB0_5 Depth=1
	ldr	x13, [sp, #216]                 // 8-byte Folded Reload
	add	x12, x13, x12
	ldr	x13, [sp, #80]                  // 8-byte Folded Reload
	add	x11, x13, x11, lsl #2
	.p2align	4, , 8
.LBB0_53:                               //   Parent Loop BB0_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	lsr	w13, w10, #1
	tst	x10, #0x1
	ldr	s6, [x11, x10, lsl #2]
	add	x10, x10, #1
	ldrb	w13, [x12, x13]
	lsr	w15, w13, #4
	and	w13, w13, #0xf
	csel	w13, w13, w15, eq
	cmp	x10, x9
	ldr	s5, [x23, w13, uxtw #2]
	fmadd	s1, s5, s6, s1
	b.lo	.LBB0_53
.LBB0_54:                               //   in Loop: Header=BB0_5 Depth=1
	fadd	s1, s2, s1
	fadd	s2, s3, s4
	fadd	s1, s2, s1
	fadd	s0, s0, s1
	ldr	s1, [x25, x8, lsl #2]
	fmul	s0, s0, s1
.LBB0_55:                               //   in Loop: Header=BB0_5 Depth=1
	ldr	x8, [sp, #144]                  // 8-byte Folded Reload
	cmp	x8, #1
	b.eq	.LBB0_4
// %bb.56:                              //   in Loop: Header=BB0_5 Depth=1
	add	x10, x28, #1
	ldrb	w8, [x26, x10]
	cmp	x8, #255
	b.eq	.LBB0_65
// %bb.57:                              //   in Loop: Header=BB0_5 Depth=1
	mul	x11, x10, x14
	ldr	x12, [sp, #200]                 // 8-byte Folded Reload
	sub	w9, w4, w11
	mul	x12, x10, x12
	cmp	w9, w6
	csel	w9, w9, w6, lt
	cmp	w9, #4
	b.lt	.LBB0_61
// %bb.58:                              //   in Loop: Header=BB0_5 Depth=1
	ldr	x13, [sp, #72]                  // 8-byte Folded Reload
	movi	d1, #0000000000000000
	ldr	x16, [sp, #16]                  // 8-byte Folded Reload
	movi	d4, #0000000000000000
	movi	d3, #0000000000000000
	movi	d2, #0000000000000000
	mov	x15, xzr
	madd	x17, x16, x10, x13
	ldr	x10, [sp, #184]                 // 8-byte Folded Reload
	add	x10, x10, x12
	.p2align	4, , 8
.LBB0_59:                               //   Parent Loop BB0_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldurb	w13, [x10, #-1]
	ldrb	w16, [x10], #2
	ldp	s5, s6, [x17, #-8]
	add	x13, x21, x13, lsl #3
	add	x16, x21, x16, lsl #3
	ldp	s19, s20, [x17], #16
	ldp	s7, s16, [x13]
	ldp	s17, s18, [x16]
	add	x13, x15, #7
	add	x15, x15, #4
	cmp	x13, x9
	fmadd	s1, s7, s5, s1
	fmadd	s2, s16, s6, s2
	fmadd	s3, s17, s19, s3
	fmadd	s4, s18, s20, s4
	b.lo	.LBB0_59
// %bb.60:                              //   in Loop: Header=BB0_5 Depth=1
	mov	w10, w15
	cmp	w10, w9
	b.lt	.LBB0_62
	b	.LBB0_64
.LBB0_61:                               //   in Loop: Header=BB0_5 Depth=1
	movi	d2, #0000000000000000
	movi	d3, #0000000000000000
	movi	d4, #0000000000000000
	movi	d1, #0000000000000000
	mov	x10, xzr
	cmp	w10, w9
	b.ge	.LBB0_64
.LBB0_62:                               //   in Loop: Header=BB0_5 Depth=1
	ldr	x13, [sp, #216]                 // 8-byte Folded Reload
	add	x12, x13, x12
	ldr	x13, [sp, #80]                  // 8-byte Folded Reload
	add	x11, x13, x11, lsl #2
	.p2align	4, , 8
.LBB0_63:                               //   Parent Loop BB0_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	lsr	w13, w10, #1
	tst	x10, #0x1
	ldr	s6, [x11, x10, lsl #2]
	add	x10, x10, #1
	ldrb	w13, [x12, x13]
	lsr	w15, w13, #4
	and	w13, w13, #0xf
	csel	w13, w13, w15, eq
	cmp	x10, x9
	ldr	s5, [x23, w13, uxtw #2]
	fmadd	s1, s5, s6, s1
	b.lo	.LBB0_63
.LBB0_64:                               //   in Loop: Header=BB0_5 Depth=1
	fadd	s1, s2, s1
	fadd	s2, s3, s4
	fadd	s1, s2, s1
	fadd	s0, s0, s1
	ldr	s1, [x25, x8, lsl #2]
	fmul	s0, s0, s1
.LBB0_65:                               //   in Loop: Header=BB0_5 Depth=1
	ldr	x8, [sp, #144]                  // 8-byte Folded Reload
	cmp	x8, #2
	b.eq	.LBB0_4
// %bb.66:                              //   in Loop: Header=BB0_5 Depth=1
	add	x10, x28, #2
	ldrb	w8, [x26, x10]
	cmp	x8, #255
	b.eq	.LBB0_4
// %bb.67:                              //   in Loop: Header=BB0_5 Depth=1
	mul	x11, x10, x14
	ldr	x12, [sp, #200]                 // 8-byte Folded Reload
	sub	w9, w4, w11
	mul	x12, x10, x12
	cmp	w9, w6
	csel	w9, w9, w6, lt
	cmp	w9, #4
	b.lt	.LBB0_71
// %bb.68:                              //   in Loop: Header=BB0_5 Depth=1
	ldr	x13, [sp, #72]                  // 8-byte Folded Reload
	movi	d1, #0000000000000000
	ldr	x16, [sp, #16]                  // 8-byte Folded Reload
	movi	d4, #0000000000000000
	movi	d3, #0000000000000000
	movi	d2, #0000000000000000
	mov	x15, xzr
	madd	x17, x16, x10, x13
	ldr	x10, [sp, #184]                 // 8-byte Folded Reload
	add	x10, x10, x12
	.p2align	4, , 8
.LBB0_69:                               //   Parent Loop BB0_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldurb	w13, [x10, #-1]
	ldrb	w16, [x10], #2
	ldp	s5, s6, [x17, #-8]
	add	x13, x21, x13, lsl #3
	add	x16, x21, x16, lsl #3
	ldp	s19, s20, [x17], #16
	ldp	s7, s16, [x13]
	ldp	s17, s18, [x16]
	add	x13, x15, #7
	add	x15, x15, #4
	cmp	x13, x9
	fmadd	s1, s7, s5, s1
	fmadd	s2, s16, s6, s2
	fmadd	s3, s17, s19, s3
	fmadd	s4, s18, s20, s4
	b.lo	.LBB0_69
// %bb.70:                              //   in Loop: Header=BB0_5 Depth=1
	mov	w10, w15
	cmp	w10, w9
	b.ge	.LBB0_3
	b	.LBB0_72
.LBB0_71:                               //   in Loop: Header=BB0_5 Depth=1
	movi	d2, #0000000000000000
	movi	d3, #0000000000000000
	movi	d4, #0000000000000000
	movi	d1, #0000000000000000
	mov	x10, xzr
	cmp	w10, w9
	b.ge	.LBB0_3
.LBB0_72:                               //   in Loop: Header=BB0_5 Depth=1
	ldr	x13, [sp, #216]                 // 8-byte Folded Reload
	add	x12, x13, x12
	ldr	x13, [sp, #80]                  // 8-byte Folded Reload
	add	x11, x13, x11, lsl #2
	.p2align	4, , 8
.LBB0_73:                               //   Parent Loop BB0_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	lsr	w13, w10, #1
	tst	x10, #0x1
	ldr	s6, [x11, x10, lsl #2]
	add	x10, x10, #1
	ldrb	w13, [x12, x13]
	lsr	w15, w13, #4
	and	w13, w13, #0xf
	csel	w13, w13, w15, eq
	cmp	x10, x9
	ldr	s5, [x23, w13, uxtw #2]
	fmadd	s1, s5, s6, s1
	b.lo	.LBB0_73
	b	.LBB0_3
.LBB0_74:
	ldp	x20, x19, [sp, #288]            // 16-byte Folded Reload
	ldp	x22, x21, [sp, #272]            // 16-byte Folded Reload
	ldp	x24, x23, [sp, #256]            // 16-byte Folded Reload
	ldp	x26, x25, [sp, #240]            // 16-byte Folded Reload
	ldp	x28, x27, [sp, #224]            // 16-byte Folded Reload
	ldr	x30, [sp, #208]                 // 8-byte Folded Reload
	add	sp, sp, #304
	.cfi_def_cfa_offset 0
	.cfi_restore w19
	.cfi_restore w20
	.cfi_restore w21
	.cfi_restore w22
	.cfi_restore w23
	.cfi_restore w24
	.cfi_restore w25
	.cfi_restore w26
	.cfi_restore w27
	.cfi_restore w28
	.cfi_restore w30
	ret
.LBB0_75:
	.cfi_restore_state
	ldp	x20, x19, [sp, #288]            // 16-byte Folded Reload
	lsl	x2, x0, #2
	mov	w1, wzr
	ldp	x22, x21, [sp, #272]            // 16-byte Folded Reload
	ldp	x24, x23, [sp, #256]            // 16-byte Folded Reload
	ldp	x26, x25, [sp, #240]            // 16-byte Folded Reload
	ldp	x28, x27, [sp, #224]            // 16-byte Folded Reload
	ldr	x0, [sp, #128]                  // 8-byte Folded Reload
	ldr	x30, [sp, #208]                 // 8-byte Folded Reload
	add	sp, sp, #304
	.cfi_def_cfa_offset 0
	.cfi_restore w19
	.cfi_restore w20
	.cfi_restore w21
	.cfi_restore w22
	.cfi_restore w23
	.cfi_restore w24
	.cfi_restore w25
	.cfi_restore w26
	.cfi_restore w27
	.cfi_restore w28
	.cfi_restore w30
	b	memset
.Lfunc_end0:
	.size	pim_mxfp4_gemv_opt, .Lfunc_end0-pim_mxfp4_gemv_opt
	.cfi_endproc
                                        // -- End function
	.globl	pim_mxfp4_gemv_opt_v2           // -- Begin function pim_mxfp4_gemv_opt_v2
	.p2align	4
	.type	pim_mxfp4_gemv_opt_v2,@function
pim_mxfp4_gemv_opt_v2:                  // @pim_mxfp4_gemv_opt_v2
	.cfi_startproc
// %bb.0:
	sub	sp, sp, #384
	.cfi_def_cfa_offset 384
	str	x30, [sp, #288]                 // 8-byte Folded Spill
	stp	x28, x27, [sp, #304]            // 16-byte Folded Spill
	stp	x26, x25, [sp, #320]            // 16-byte Folded Spill
	stp	x24, x23, [sp, #336]            // 16-byte Folded Spill
	stp	x22, x21, [sp, #352]            // 16-byte Folded Spill
	stp	x20, x19, [sp, #368]            // 16-byte Folded Spill
	.cfi_offset w19, -8
	.cfi_offset w20, -16
	.cfi_offset w21, -24
	.cfi_offset w22, -32
	.cfi_offset w23, -40
	.cfi_offset w24, -48
	.cfi_offset w25, -56
	.cfi_offset w26, -64
	.cfi_offset w27, -72
	.cfi_offset w28, -80
	.cfi_offset w30, -96
	.cfi_remember_state
	cmp	w5, #1
                                        // kill: def $w6 killed $w6 def $x6
	stp	x3, x0, [sp, #88]               // 16-byte Folded Spill
	b.lt	.LBB1_62
// %bb.1:
	add	w8, w4, w6
	mov	x20, x1
	sub	w8, w8, #1
	mov	w1, w5
	sdiv	w12, w8, w6
	cmp	w12, #0
	b.le	.LBB1_63
// %bb.2:
	add	w8, w4, w4, lsr #31
	add	w9, w6, w6, lsr #31
	sbfx	x10, x8, #1, #31
	sxtw	x8, w12
	add	x17, sp, #160
	sxtw	x21, w6
	mov	x5, xzr
	neg	w15, w6
	stp	x8, x10, [sp, #56]              // 16-byte Folded Spill
	sbfx	x8, x9, #1, #31
	add	x9, x17, #4
	lsl	x24, x8, #1
	and	x19, x12, #0x7ffffffe
	lsl	x22, x21, #3
	adrp	x28, PIM_E2M1
	add	x28, x28, :lo12:PIM_E2M1
	stp	x9, x8, [sp, #136]              // 16-byte Folded Spill
	lsl	w8, w6, #1
	sub	w9, w4, w6
	stp	x12, x1, [sp, #72]              // 16-byte Folded Spill
	str	w8, [sp, #156]                  // 4-byte Folded Spill
	add	x8, x17, #32
	str	w9, [sp, #44]                   // 4-byte Folded Spill
	lsl	x9, x21, #2
	stp	x8, x20, [sp, #120]             // 16-byte Folded Spill
	add	x8, x20, #32
	str	x8, [sp, #48]                   // 8-byte Folded Spill
	add	x8, x8, x9
	str	x8, [sp, #32]                   // 8-byte Folded Spill
	add	x8, x20, x9
	stp	x9, x8, [sp, #16]               // 16-byte Folded Spill
	b	.LBB1_5
	.p2align	4, , 8
.LBB1_3:                                //   in Loop: Header=BB1_5 Depth=1
	dup	v3.4s, v1.s[3]
	mov	s4, v1.s[1]
	adrp	x8, :got:PIM_E8M0
	ldr	x8, [x8, :got_lo12:PIM_E8M0]
	fadd	v1.4s, v1.4s, v3.4s
	fadd	s2, s4, s2
	mov	s1, v1.s[2]
	fadd	s1, s1, s2
	fadd	s0, s0, s1
	ldr	s1, [x8, x9, lsl #2]
	fmul	s0, s0, s1
.LBB1_4:                                //   in Loop: Header=BB1_5 Depth=1
	ldr	x8, [sp, #96]                   // 8-byte Folded Reload
	str	s0, [x8, x5, lsl #2]
	ldr	x8, [sp, #64]                   // 8-byte Folded Reload
	add	x5, x5, #1
	cmp	x5, x1
	add	x2, x2, x8
	b.eq	.LBB1_62
.LBB1_5:                                // =>This Loop Header: Depth=1
                                        //     Child Loop BB1_18 Depth 2
                                        //       Child Loop BB1_21 Depth 3
                                        //       Child Loop BB1_39 Depth 3
                                        //       Child Loop BB1_26 Depth 3
                                        //       Child Loop BB1_31 Depth 3
                                        //       Child Loop BB1_46 Depth 3
                                        //       Child Loop BB1_52 Depth 3
                                        //     Child Loop BB1_11 Depth 2
                                        //     Child Loop BB1_57 Depth 2
                                        //     Child Loop BB1_55 Depth 2
	ldr	x8, [sp, #88]                   // 8-byte Folded Reload
	cmp	w12, #1
	ldr	x9, [sp, #56]                   // 8-byte Folded Reload
	stp	x5, x2, [sp, #104]              // 16-byte Folded Spill
	nop
	madd	x16, x5, x9, x8
	b.ne	.LBB1_15
// %bb.6:                               //   in Loop: Header=BB1_5 Depth=1
	movi	d0, #0000000000000000
	mov	x30, xzr
.LBB1_7:                                //   in Loop: Header=BB1_5 Depth=1
	ldp	x5, x2, [sp, #104]              // 16-byte Folded Reload
	ldp	x12, x1, [sp, #72]              // 16-byte Folded Reload
	tbz	w12, #0, .LBB1_4
// %bb.8:                               //   in Loop: Header=BB1_5 Depth=1
	madd	w8, w30, w15, w4
	ldrb	w9, [x16, x30]
	cmp	w6, w8
	csel	w8, w6, w8, lt
	cmp	x9, #255
	b.eq	.LBB1_4
// %bb.9:                               //   in Loop: Header=BB1_5 Depth=1
	mul	x10, x30, x21
	movi	v1.2d, #0000000000000000
	sub	w13, w4, w10
	cmp	w13, w6
	add	x11, x20, x10, lsl #2
	csel	w0, w13, w6, lt
	cmp	w0, #1
	b.lt	.LBB1_53
// %bb.10:                              //   in Loop: Header=BB1_5 Depth=1
	ldr	x13, [sp, #144]                 // 8-byte Folded Reload
	sub	x8, x8, #4
	lsr	x16, x8, #2
	mov	x10, xzr
	add	x14, x16, #1
	mul	x13, x30, x13
	.p2align	4, , 8
.LBB1_11:                               //   Parent Loop BB1_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldrb	w16, [x2, x13]
	add	x13, x13, #1
	and	x3, x16, #0xf
	lsr	x16, x16, #4
	ldr	s2, [x28, x3, lsl #2]
	add	x3, x17, x10, lsl #2
	ldr	s3, [x28, x16, lsl #2]
	add	x10, x10, #2
	cmp	x10, x0
	stp	s2, s3, [x3]
	b.lo	.LBB1_11
// %bb.12:                              //   in Loop: Header=BB1_5 Depth=1
	cmp	w0, #4
	b.lo	.LBB1_53
// %bb.13:                              //   in Loop: Header=BB1_5 Depth=1
	cmp	x8, #12
	b.hs	.LBB1_56
// %bb.14:                              //   in Loop: Header=BB1_5 Depth=1
	movi	v1.2d, #0000000000000000
	mov	x16, xzr
	b	.LBB1_58
	.p2align	4, , 8
.LBB1_15:                               //   in Loop: Header=BB1_5 Depth=1
	ldp	x26, x25, [sp, #24]             // 16-byte Folded Reload
	movi	d0, #0000000000000000
	mov	x30, xzr
	ldr	w23, [sp, #44]                  // 4-byte Folded Reload
	mov	x14, x20
	ldr	x27, [sp, #48]                  // 8-byte Folded Reload
	mov	w1, w4
	ldr	w12, [sp, #156]                 // 4-byte Folded Reload
	str	x16, [sp, #296]                 // 8-byte Folded Spill
	b	.LBB1_18
	.p2align	4, , 8
.LBB1_16:                               //   in Loop: Header=BB1_18 Depth=2
	dup	v3.4s, v1.s[3]
	mov	s4, v1.s[1]
	adrp	x8, :got:PIM_E8M0
	ldr	x8, [x8, :got_lo12:PIM_E8M0]
	fadd	v1.4s, v1.4s, v3.4s
	fadd	s2, s4, s2
	mov	s1, v1.s[2]
	fadd	s1, s1, s2
	fadd	s0, s0, s1
	ldr	s1, [x8, x3, lsl #2]
	fmul	s0, s0, s1
.LBB1_17:                               //   in Loop: Header=BB1_18 Depth=2
	add	x30, x30, #2
	add	x2, x2, x24
	sub	w1, w1, w12
	add	x27, x27, x22
	add	x14, x14, x22
	sub	w23, w23, w12
	add	x25, x25, x22
	add	x26, x26, x22
	cmp	x30, x19
	b.eq	.LBB1_7
.LBB1_18:                               //   Parent Loop BB1_5 Depth=1
                                        // =>  This Loop Header: Depth=2
                                        //       Child Loop BB1_21 Depth 3
                                        //       Child Loop BB1_39 Depth 3
                                        //       Child Loop BB1_26 Depth 3
                                        //       Child Loop BB1_31 Depth 3
                                        //       Child Loop BB1_46 Depth 3
                                        //       Child Loop BB1_52 Depth 3
	cmp	w6, w23
	madd	w8, w30, w15, w4
	ldrb	w3, [x16, x30]
	csel	w9, w6, w23, lt
	cmp	w6, w1
	csel	w13, w6, w1, lt
	cmp	w6, w8
	csel	w10, w6, w8, lt
	cmp	x3, #255
	b.eq	.LBB1_28
// %bb.19:                              //   in Loop: Header=BB1_18 Depth=2
	mul	x11, x30, x21
	movi	v1.2d, #0000000000000000
	sub	w8, w4, w11
	cmp	w8, w6
	csel	w0, w8, w6, lt
	cmp	w0, #1
	b.lt	.LBB1_25
// %bb.20:                              //   in Loop: Header=BB1_18 Depth=2
	sub	x13, x13, #4
	sub	x10, x10, #4
	lsr	x13, x13, #2
	lsr	x5, x10, #2
	add	x13, x13, #1
	mov	x12, x24
	mov	w24, w15
	mov	x15, x19
	mov	x19, x21
	mov	x8, xzr
	add	x5, x5, #1
	and	x13, x13, #0x7ffffffffffffffc
	add	x20, x20, x11, lsl #2
	mov	x11, x2
	ldr	x21, [sp, #136]                 // 8-byte Folded Reload
	.p2align	4, , 8
.LBB1_21:                               //   Parent Loop BB1_5 Depth=1
                                        //     Parent Loop BB1_18 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldrb	w16, [x11], #1
	add	x8, x8, #2
	cmp	x8, x0
	and	x7, x16, #0xf
	lsr	x16, x16, #4
	ldr	s2, [x28, x7, lsl #2]
	ldr	s3, [x28, x16, lsl #2]
	stp	s2, s3, [x21, #-4]
	add	x21, x21, #8
	b.lo	.LBB1_21
// %bb.22:                              //   in Loop: Header=BB1_18 Depth=2
	cmp	w0, #4
	b.lo	.LBB1_36
// %bb.23:                              //   in Loop: Header=BB1_18 Depth=2
	mov	x21, x19
	cmp	x10, #12
	b.hs	.LBB1_38
// %bb.24:                              //   in Loop: Header=BB1_18 Depth=2
	movi	v1.2d, #0000000000000000
	mov	x10, xzr
	mov	x19, x15
	b	.LBB1_40
	.p2align	4, , 8
.LBB1_25:                               //   in Loop: Header=BB1_18 Depth=2
	mov	x13, xzr
	fmov	s2, s1
	cmp	w13, w0
	b.ge	.LBB1_27
	.p2align	4, , 8
.LBB1_26:                               //   Parent Loop BB1_5 Depth=1
                                        //     Parent Loop BB1_18 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldr	s3, [x17, x13, lsl #2]
	ldr	s4, [x14, x13, lsl #2]
	add	x13, x13, #1
	cmp	x13, x0
	fmadd	s2, s3, s4, s2
	b.lo	.LBB1_26
.LBB1_27:                               //   in Loop: Header=BB1_18 Depth=2
	dup	v3.4s, v1.s[3]
	mov	s4, v1.s[1]
	adrp	x8, :got:PIM_E8M0
	ldr	x8, [x8, :got_lo12:PIM_E8M0]
	fadd	v1.4s, v1.4s, v3.4s
	fadd	s2, s4, s2
	mov	s1, v1.s[2]
	fadd	s1, s1, s2
	fadd	s0, s0, s1
	ldr	s1, [x8, x3, lsl #2]
	fmul	s0, s0, s1
.LBB1_28:                               //   in Loop: Header=BB1_18 Depth=2
	orr	x8, x30, #0x1
	madd	w10, w8, w15, w4
	ldrb	w3, [x16, x8]
	cmp	w6, w10
	csel	w10, w6, w10, lt
	cmp	x3, #255
	b.eq	.LBB1_17
// %bb.29:                              //   in Loop: Header=BB1_18 Depth=2
	mul	x13, x8, x21
	movi	v1.2d, #0000000000000000
	sub	w8, w4, w13
	cmp	w8, w6
	csel	w0, w8, w6, lt
	cmp	w0, #1
	b.lt	.LBB1_35
// %bb.30:                              //   in Loop: Header=BB1_18 Depth=2
	sub	x9, x9, #4
	sub	x11, x10, #4
	lsr	x9, x9, #2
	lsr	x10, x11, #2
	add	x9, x9, #1
	mov	x8, xzr
	add	x5, x10, #1
	and	x10, x9, #0x7ffffffffffffffc
	add	x9, x20, x13, lsl #2
	ldr	x13, [sp, #144]                 // 8-byte Folded Reload
	.p2align	4, , 8
.LBB1_31:                               //   Parent Loop BB1_5 Depth=1
                                        //     Parent Loop BB1_18 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldrb	w16, [x2, x13]
	add	x13, x13, #1
	and	x7, x16, #0xf
	lsr	x16, x16, #4
	ldr	s2, [x28, x7, lsl #2]
	add	x7, x17, x8, lsl #2
	ldr	s3, [x28, x16, lsl #2]
	add	x8, x8, #2
	cmp	x8, x0
	stp	s2, s3, [x7]
	b.lo	.LBB1_31
// %bb.32:                              //   in Loop: Header=BB1_18 Depth=2
	cmp	w0, #4
	b.lo	.LBB1_37
// %bb.33:                              //   in Loop: Header=BB1_18 Depth=2
	cmp	x11, #12
	b.hs	.LBB1_45
// %bb.34:                              //   in Loop: Header=BB1_18 Depth=2
	movi	v1.2d, #0000000000000000
	mov	x13, xzr
	b	.LBB1_47
	.p2align	4, , 8
.LBB1_35:                               //   in Loop: Header=BB1_18 Depth=2
	mov	x10, xzr
	b	.LBB1_51
.LBB1_36:                               //   in Loop: Header=BB1_18 Depth=2
	ldr	x20, [sp, #128]                 // 8-byte Folded Reload
	mov	x21, x19
	mov	x19, x15
	mov	w15, w24
	mov	x24, x12
	ldr	w12, [sp, #156]                 // 4-byte Folded Reload
	ldr	x16, [sp, #296]                 // 8-byte Folded Reload
	mov	x13, xzr
	fmov	s2, s1
	cmp	w13, w0
	b.lt	.LBB1_26
	b	.LBB1_27
.LBB1_37:                               //   in Loop: Header=BB1_18 Depth=2
	ldr	x16, [sp, #296]                 // 8-byte Folded Reload
	mov	x10, xzr
	b	.LBB1_51
.LBB1_38:                               //   in Loop: Header=BB1_18 Depth=2
	movi	v1.2d, #0000000000000000
	mov	x10, xzr
	mov	x11, x27
	ldr	x8, [sp, #120]                  // 8-byte Folded Reload
	mov	x19, x15
	.p2align	4, , 8
.LBB1_39:                               //   Parent Loop BB1_5 Depth=1
                                        //     Parent Loop BB1_18 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldp	q2, q5, [x11, #-32]
	add	x10, x10, #16
	subs	x13, x13, #4
	ldp	q3, q4, [x8, #-32]
	fmla	v1.4s, v2.4s, v3.4s
	fmla	v1.4s, v5.4s, v4.4s
	ldp	q2, q5, [x11], #64
	ldp	q3, q4, [x8], #64
	fmla	v1.4s, v2.4s, v3.4s
	fmla	v1.4s, v5.4s, v4.4s
	b.ne	.LBB1_39
.LBB1_40:                               //   in Loop: Header=BB1_18 Depth=2
	and	x8, x5, #0x3
	mov	x13, x10
	mov	w15, w24
	mov	x24, x12
	ldr	w12, [sp, #156]                 // 4-byte Folded Reload
	ldr	x16, [sp, #296]                 // 8-byte Folded Reload
	cbz	x8, .LBB1_44
// %bb.41:                              //   in Loop: Header=BB1_18 Depth=2
	lsl	x11, x10, #2
	add	x13, x10, #4
	cmp	x8, #1
	ldr	q2, [x17, x11]
	ldr	q3, [x20, x11]
	fmla	v1.4s, v3.4s, v2.4s
	b.eq	.LBB1_44
// %bb.42:                              //   in Loop: Header=BB1_18 Depth=2
	lsl	x11, x13, #2
	add	x13, x10, #8
	cmp	x8, #2
	ldr	q2, [x17, x11]
	ldr	q3, [x20, x11]
	fmla	v1.4s, v3.4s, v2.4s
	b.eq	.LBB1_44
// %bb.43:                              //   in Loop: Header=BB1_18 Depth=2
	lsl	x8, x13, #2
	add	x13, x10, #12
	ldr	q2, [x17, x8]
	ldr	q3, [x20, x8]
	fmla	v1.4s, v3.4s, v2.4s
.LBB1_44:                               //   in Loop: Header=BB1_18 Depth=2
	ldr	x20, [sp, #128]                 // 8-byte Folded Reload
	fmov	s2, s1
	cmp	w13, w0
	b.ge	.LBB1_27
	b	.LBB1_26
.LBB1_45:                               //   in Loop: Header=BB1_18 Depth=2
	movi	v1.2d, #0000000000000000
	mov	x13, xzr
	mov	x8, x25
	ldr	x11, [sp, #120]                 // 8-byte Folded Reload
	.p2align	4, , 8
.LBB1_46:                               //   Parent Loop BB1_5 Depth=1
                                        //     Parent Loop BB1_18 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldp	q2, q5, [x8, #-32]
	add	x13, x13, #16
	subs	x10, x10, #4
	ldp	q3, q4, [x11, #-32]
	fmla	v1.4s, v2.4s, v3.4s
	fmla	v1.4s, v5.4s, v4.4s
	ldp	q2, q5, [x8], #64
	ldp	q3, q4, [x11], #64
	fmla	v1.4s, v2.4s, v3.4s
	fmla	v1.4s, v5.4s, v4.4s
	b.ne	.LBB1_46
.LBB1_47:                               //   in Loop: Header=BB1_18 Depth=2
	and	x8, x5, #0x3
	mov	x10, x13
	ldr	x16, [sp, #296]                 // 8-byte Folded Reload
	cbz	x8, .LBB1_51
// %bb.48:                              //   in Loop: Header=BB1_18 Depth=2
	lsl	x10, x13, #2
	cmp	x8, #1
	ldr	q2, [x17, x10]
	ldr	q3, [x9, x10]
	add	x10, x13, #4
	fmla	v1.4s, v3.4s, v2.4s
	b.eq	.LBB1_51
// %bb.49:                              //   in Loop: Header=BB1_18 Depth=2
	lsl	x10, x10, #2
	cmp	x8, #2
	ldr	q2, [x17, x10]
	ldr	q3, [x9, x10]
	add	x10, x13, #8
	fmla	v1.4s, v3.4s, v2.4s
	b.eq	.LBB1_51
// %bb.50:                              //   in Loop: Header=BB1_18 Depth=2
	lsl	x8, x10, #2
	add	x10, x13, #12
	ldr	q2, [x17, x8]
	ldr	q3, [x9, x8]
	fmla	v1.4s, v3.4s, v2.4s
	.p2align	4, , 8
.LBB1_51:                               //   in Loop: Header=BB1_18 Depth=2
	fmov	s2, s1
	cmp	w10, w0
	b.ge	.LBB1_16
	.p2align	4, , 8
.LBB1_52:                               //   Parent Loop BB1_5 Depth=1
                                        //     Parent Loop BB1_18 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldr	s3, [x17, x10, lsl #2]
	ldr	s4, [x26, x10, lsl #2]
	add	x10, x10, #1
	cmp	x10, x0
	fmadd	s2, s3, s4, s2
	b.lo	.LBB1_52
	b	.LBB1_16
	.p2align	4, , 8
.LBB1_53:                               //   in Loop: Header=BB1_5 Depth=1
	mov	x10, xzr
.LBB1_54:                               //   in Loop: Header=BB1_5 Depth=1
	fmov	s2, s1
	cmp	w10, w0
	b.ge	.LBB1_3
	.p2align	4, , 8
.LBB1_55:                               //   Parent Loop BB1_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldr	s3, [x17, x10, lsl #2]
	ldr	s4, [x11, x10, lsl #2]
	add	x10, x10, #1
	cmp	x10, x0
	fmadd	s2, s3, s4, s2
	b.lo	.LBB1_55
	b	.LBB1_3
.LBB1_56:                               //   in Loop: Header=BB1_5 Depth=1
	ldr	x8, [sp, #48]                   // 8-byte Folded Reload
	mov	x16, xzr
	ldr	x10, [sp, #16]                  // 8-byte Folded Reload
	and	x13, x14, #0x7ffffffffffffffc
	movi	v1.2d, #0000000000000000
	madd	x10, x10, x30, x8
	ldr	x8, [sp, #120]                  // 8-byte Folded Reload
	.p2align	4, , 8
.LBB1_57:                               //   Parent Loop BB1_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldp	q2, q5, [x10, #-32]
	add	x16, x16, #16
	subs	x13, x13, #4
	ldp	q3, q4, [x8, #-32]
	fmla	v1.4s, v2.4s, v3.4s
	fmla	v1.4s, v5.4s, v4.4s
	ldp	q2, q5, [x10], #64
	ldp	q3, q4, [x8], #64
	fmla	v1.4s, v2.4s, v3.4s
	fmla	v1.4s, v5.4s, v4.4s
	b.ne	.LBB1_57
.LBB1_58:                               //   in Loop: Header=BB1_5 Depth=1
	and	x8, x14, #0x3
	mov	x10, x16
	cbz	x8, .LBB1_54
// %bb.59:                              //   in Loop: Header=BB1_5 Depth=1
	lsl	x10, x16, #2
	cmp	x8, #1
	ldr	q2, [x17, x10]
	ldr	q3, [x11, x10]
	add	x10, x16, #4
	fmla	v1.4s, v3.4s, v2.4s
	b.eq	.LBB1_54
// %bb.60:                              //   in Loop: Header=BB1_5 Depth=1
	lsl	x10, x10, #2
	cmp	x8, #2
	ldr	q2, [x17, x10]
	ldr	q3, [x11, x10]
	add	x10, x16, #8
	fmla	v1.4s, v3.4s, v2.4s
	b.eq	.LBB1_54
// %bb.61:                              //   in Loop: Header=BB1_5 Depth=1
	lsl	x8, x10, #2
	add	x10, x16, #12
	ldr	q2, [x17, x8]
	ldr	q3, [x11, x8]
	fmla	v1.4s, v3.4s, v2.4s
	b	.LBB1_54
.LBB1_62:
	ldp	x20, x19, [sp, #368]            // 16-byte Folded Reload
	ldp	x22, x21, [sp, #352]            // 16-byte Folded Reload
	ldp	x24, x23, [sp, #336]            // 16-byte Folded Reload
	ldp	x26, x25, [sp, #320]            // 16-byte Folded Reload
	ldp	x28, x27, [sp, #304]            // 16-byte Folded Reload
	ldr	x30, [sp, #288]                 // 8-byte Folded Reload
	add	sp, sp, #384
	.cfi_def_cfa_offset 0
	.cfi_restore w19
	.cfi_restore w20
	.cfi_restore w21
	.cfi_restore w22
	.cfi_restore w23
	.cfi_restore w24
	.cfi_restore w25
	.cfi_restore w26
	.cfi_restore w27
	.cfi_restore w28
	.cfi_restore w30
	ret
.LBB1_63:
	.cfi_restore_state
	ldp	x20, x19, [sp, #368]            // 16-byte Folded Reload
	lsl	x2, x1, #2
	mov	w1, wzr
	ldp	x22, x21, [sp, #352]            // 16-byte Folded Reload
	ldp	x24, x23, [sp, #336]            // 16-byte Folded Reload
	ldp	x26, x25, [sp, #320]            // 16-byte Folded Reload
	ldp	x28, x27, [sp, #304]            // 16-byte Folded Reload
	ldr	x0, [sp, #96]                   // 8-byte Folded Reload
	ldr	x30, [sp, #288]                 // 8-byte Folded Reload
	add	sp, sp, #384
	.cfi_def_cfa_offset 0
	.cfi_restore w19
	.cfi_restore w20
	.cfi_restore w21
	.cfi_restore w22
	.cfi_restore w23
	.cfi_restore w24
	.cfi_restore w25
	.cfi_restore w26
	.cfi_restore w27
	.cfi_restore w28
	.cfi_restore w30
	b	memset
.Lfunc_end1:
	.size	pim_mxfp4_gemv_opt_v2, .Lfunc_end1-pim_mxfp4_gemv_opt_v2
	.cfi_endproc
                                        // -- End function
	.globl	pim_mxfp4_gemv_opt_v3           // -- Begin function pim_mxfp4_gemv_opt_v3
	.p2align	4
	.type	pim_mxfp4_gemv_opt_v3,@function
pim_mxfp4_gemv_opt_v3:                  // @pim_mxfp4_gemv_opt_v3
	.cfi_startproc
// %bb.0:
	sub	sp, sp, #304
	.cfi_def_cfa_offset 304
	str	x30, [sp, #208]                 // 8-byte Folded Spill
	stp	x28, x27, [sp, #224]            // 16-byte Folded Spill
	stp	x26, x25, [sp, #240]            // 16-byte Folded Spill
	stp	x24, x23, [sp, #256]            // 16-byte Folded Spill
	stp	x22, x21, [sp, #272]            // 16-byte Folded Spill
	stp	x20, x19, [sp, #288]            // 16-byte Folded Spill
	.cfi_offset w19, -8
	.cfi_offset w20, -16
	.cfi_offset w21, -24
	.cfi_offset w22, -32
	.cfi_offset w23, -40
	.cfi_offset w24, -48
	.cfi_offset w25, -56
	.cfi_offset w26, -64
	.cfi_offset w27, -72
	.cfi_offset w28, -80
	.cfi_offset w30, -96
	.cfi_remember_state
	adrp	x8, .L_MergedGlobals
	ldrb	w9, [x8, :lo12:.L_MergedGlobals]
                                        // kill: def $w6 killed $w6 def $x6
	stp	x3, x0, [sp, #104]              // 16-byte Folded Spill
	str	x2, [sp, #120]                  // 8-byte Folded Spill
	str	x1, [sp, #64]                   // 8-byte Folded Spill
	tbnz	w9, #0, .LBB2_4
// %bb.1:
	mov	x9, xzr
	adrp	x10, .L_MergedGlobals+8
	add	x10, x10, :lo12:.L_MergedGlobals+8
	adrp	x11, PIM_E2M1
	add	x11, x11, :lo12:PIM_E2M1
	.p2align	4, , 8
.LBB2_2:                                // =>This Inner Loop Header: Depth=1
	and	x12, x9, #0xf
	lsr	w13, w9, #4
	add	x9, x9, #1
	cmp	x9, #256
	ldr	s0, [x11, x12, lsl #2]
	ldr	s1, [x11, x13, lsl #2]
	stp	s0, s1, [x10, #-4]
	add	x10, x10, #8
	b.ne	.LBB2_2
// %bb.3:
	mov	w9, #1                          // =0x1
	strb	w9, [x8, :lo12:.L_MergedGlobals]
.LBB2_4:
	cmp	w5, #1
	b.lt	.LBB2_50
// %bb.5:
	add	w8, w4, w6
	mov	w5, w5
	sub	w8, w8, #1
	sdiv	w19, w8, w6
	cmp	w19, #0
	b.le	.LBB2_51
// %bb.6:
	add	w9, w6, w6, lsr #31
	ldr	x27, [sp, #120]                 // 8-byte Folded Reload
	sbfx	x24, x9, #1, #31
	sxtw	x17, w6
	lsl	x9, x24, #1
	add	w8, w4, w4, lsr #31
	add	x12, x27, #3
	lsl	x15, x17, #2
	sbfx	x11, x8, #1, #31
	sxtw	x8, w19
	str	x9, [sp, #200]                  // 8-byte Folded Spill
	ldr	x9, [sp, #64]                   // 8-byte Folded Reload
	stp	x12, x24, [sp, #160]            // 16-byte Folded Spill
	add	x25, x12, x24
	mov	x10, xzr
	stp	x8, x11, [sp, #72]              // 16-byte Folded Spill
	add	x13, x9, #16
	add	x14, x9, #8
	add	x12, x13, x15
	and	x8, x19, #0x7ffffffe
	lsl	x7, x17, #3
	add	x23, x27, x24
	add	x9, x9, x15
	adrp	x28, .L_MergedGlobals+4
	add	x28, x28, :lo12:.L_MergedGlobals+4
	str	x12, [sp, #40]                  // 8-byte Folded Spill
	add	x12, x14, x15
	adrp	x30, PIM_E2M1
	add	x30, x30, :lo12:PIM_E2M1
	str	x8, [sp, #216]                  // 8-byte Folded Spill
	stp	x14, x13, [sp, #48]             // 16-byte Folded Spill
	str	x15, [sp, #16]                  // 8-byte Folded Spill
	stp	x9, x12, [sp, #24]              // 16-byte Folded Spill
	str	x17, [sp, #176]                 // 8-byte Folded Spill
	stp	x19, x5, [sp, #88]              // 16-byte Folded Spill
	b	.LBB2_9
	.p2align	4, , 8
.LBB2_7:                                //   in Loop: Header=BB2_9 Depth=1
	fadd	s2, s16, s2
	fadd	s6, s6, s7
	fadd	s4, s4, s5
	fadd	s1, s1, s3
	adrp	x9, :got:PIM_E8M0
	ldr	x9, [x9, :got_lo12:PIM_E8M0]
	fadd	s2, s6, s2
	fadd	s1, s1, s4
	fadd	s1, s1, s2
	fadd	s0, s0, s1
	ldr	s1, [x9, x8, lsl #2]
	fmul	s0, s0, s1
.LBB2_8:                                //   in Loop: Header=BB2_9 Depth=1
	ldr	x10, [sp, #152]                 // 8-byte Folded Reload
	ldr	x8, [sp, #112]                  // 8-byte Folded Reload
	ldr	x11, [sp, #80]                  // 8-byte Folded Reload
	str	s0, [x8, x10, lsl #2]
	ldr	x8, [sp, #160]                  // 8-byte Folded Reload
	add	x10, x10, #1
	add	x27, x27, x11
	add	x25, x25, x11
	add	x8, x8, x11
	add	x23, x23, x11
	cmp	x10, x5
	str	x8, [sp, #160]                  // 8-byte Folded Spill
	b.eq	.LBB2_50
.LBB2_9:                                // =>This Loop Header: Depth=1
                                        //     Child Loop BB2_21 Depth 2
                                        //       Child Loop BB2_24 Depth 3
                                        //       Child Loop BB2_28 Depth 3
                                        //       Child Loop BB2_31 Depth 3
                                        //       Child Loop BB2_36 Depth 3
                                        //       Child Loop BB2_40 Depth 3
                                        //       Child Loop BB2_43 Depth 3
                                        //     Child Loop BB2_15 Depth 2
                                        //     Child Loop BB2_46 Depth 2
                                        //     Child Loop BB2_49 Depth 2
	ldr	x8, [sp, #120]                  // 8-byte Folded Reload
	cmp	w19, #1
	ldr	x9, [sp, #72]                   // 8-byte Folded Reload
	stp	x25, x10, [sp, #144]            // 16-byte Folded Spill
	stp	x27, x23, [sp, #128]            // 16-byte Folded Spill
	nop
	madd	x8, x10, x11, x8
	str	x8, [sp, #184]                  // 8-byte Folded Spill
	ldr	x8, [sp, #104]                  // 8-byte Folded Reload
	nop
	madd	x2, x10, x9, x8
	b.ne	.LBB2_17
// %bb.10:                              //   in Loop: Header=BB2_9 Depth=1
	movi	d0, #0000000000000000
	mov	x22, xzr
.LBB2_11:                               //   in Loop: Header=BB2_9 Depth=1
	ldp	x19, x5, [sp, #88]              // 16-byte Folded Reload
	ldp	x23, x25, [sp, #136]            // 16-byte Folded Reload
	ldr	x27, [sp, #128]                 // 8-byte Folded Reload
	tbz	w19, #0, .LBB2_8
// %bb.12:                              //   in Loop: Header=BB2_9 Depth=1
	ldrb	w8, [x2, x22]
	cmp	x8, #255
	b.eq	.LBB2_8
// %bb.13:                              //   in Loop: Header=BB2_9 Depth=1
	mul	x9, x22, x17
	mul	x12, x22, x24
	sub	w10, w4, w9
	cmp	w10, w6
	csel	w11, w10, w6, lt
	cmp	w11, #8
	b.lt	.LBB2_44
// %bb.14:                              //   in Loop: Header=BB2_9 Depth=1
	ldr	x10, [sp, #56]                  // 8-byte Folded Reload
	movi	d2, #0000000000000000
	ldr	x13, [sp, #16]                  // 8-byte Folded Reload
	movi	d16, #0000000000000000
	movi	d7, #0000000000000000
	movi	d6, #0000000000000000
	movi	d5, #0000000000000000
	movi	d4, #0000000000000000
	nop
	madd	x0, x13, x22, x10
	movi	d3, #0000000000000000
	movi	d1, #0000000000000000
	mov	x16, xzr
	mov	x1, x12
	.p2align	4, , 8
.LBB2_15:                               //   Parent Loop BB2_9 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	add	x10, x27, x1
	add	x1, x1, #4
	ldp	s17, s18, [x0, #-16]
	ldp	s19, s24, [x0, #-8]
	ldrb	w13, [x10]
	ldrb	w14, [x10, #1]
	ldrb	w15, [x10, #2]
	lsr	w2, w13, #4
	and	x13, x13, #0xf
	and	x3, x14, #0xf
	lsl	x13, x13, #3
	lsr	w14, w14, #4
	ldrb	w10, [x10, #3]
	lsl	x3, x3, #3
	add	x2, x28, w2, uxtw #3
	add	x14, x28, w14, uxtw #3
	ldr	s20, [x28, x13]
	and	x13, x15, #0xf
	lsr	w17, w15, #4
	lsl	x13, x13, #3
	ldr	s21, [x28, x3]
	ldr	s23, [x14, #4]
	lsr	w14, w10, #4
	and	x10, x10, #0xf
	ldr	s22, [x2, #4]
	lsl	x10, x10, #3
	add	x15, x28, w17, uxtw #3
	ldr	s25, [x28, x13]
	add	x13, x28, w14, uxtw #3
	ldp	s27, s28, [x0]
	ldr	s29, [x28, x10]
	fmadd	s2, s20, s17, s2
	fmadd	s7, s21, s19, s7
	ldr	s26, [x15, #4]
	ldp	s17, s19, [x0, #8]
	fmadd	s16, s22, s18, s16
	ldr	s18, [x13, #4]
	fmadd	s6, s23, s24, s6
	fmadd	s5, s25, s27, s5
	fmadd	s4, s26, s28, s4
	add	x10, x16, #15
	fmadd	s3, s29, s17, s3
	fmadd	s1, s18, s19, s1
	add	x16, x16, #8
	add	x0, x0, #32
	cmp	x10, x11
	b.lo	.LBB2_15
// %bb.16:                              //   in Loop: Header=BB2_9 Depth=1
	ldr	x17, [sp, #176]                 // 8-byte Folded Reload
	orr	w10, w16, #0x3
	cmp	w10, w11
	b.lt	.LBB2_45
	b	.LBB2_47
	.p2align	4, , 8
.LBB2_17:                               //   in Loop: Header=BB2_9 Depth=1
	ldp	x26, x5, [sp, #24]              // 16-byte Folded Reload
	movi	d0, #0000000000000000
	mov	x22, xzr
	ldp	x10, x3, [sp, #40]              // 16-byte Folded Reload
	str	x2, [sp, #192]                  // 8-byte Folded Spill
	ldp	x9, x8, [sp, #56]               // 16-byte Folded Reload
	ldr	x16, [sp, #160]                 // 8-byte Folded Reload
	b	.LBB2_21
	.p2align	4, , 8
.LBB2_18:                               //   in Loop: Header=BB2_21 Depth=2
	ldr	x2, [sp, #192]                  // 8-byte Folded Reload
.LBB2_19:                               //   in Loop: Header=BB2_21 Depth=2
	fadd	s2, s16, s2
	fadd	s6, s6, s7
	fadd	s4, s4, s5
	fadd	s1, s1, s3
	adrp	x12, :got:PIM_E8M0
	ldr	x12, [x12, :got_lo12:PIM_E8M0]
	fadd	s2, s6, s2
	fadd	s1, s1, s4
	fadd	s1, s1, s2
	fadd	s0, s0, s1
	ldr	s1, [x12, x11, lsl #2]
	fmul	s0, s0, s1
.LBB2_20:                               //   in Loop: Header=BB2_21 Depth=2
	ldr	x11, [sp, #200]                 // 8-byte Folded Reload
	add	x22, x22, #2
	add	x9, x9, x7
	add	x3, x3, x7
	add	x8, x8, x7
	add	x10, x10, x7
	add	x16, x16, x11
	add	x27, x27, x11
	add	x25, x25, x11
	add	x23, x23, x11
	ldr	x11, [sp, #216]                 // 8-byte Folded Reload
	add	x5, x5, x7
	add	x26, x26, x7
	cmp	x22, x11
	b.eq	.LBB2_11
.LBB2_21:                               //   Parent Loop BB2_9 Depth=1
                                        // =>  This Loop Header: Depth=2
                                        //       Child Loop BB2_24 Depth 3
                                        //       Child Loop BB2_28 Depth 3
                                        //       Child Loop BB2_31 Depth 3
                                        //       Child Loop BB2_36 Depth 3
                                        //       Child Loop BB2_40 Depth 3
                                        //       Child Loop BB2_43 Depth 3
	ldrb	w11, [x2, x22]
	cmp	x11, #255
	b.eq	.LBB2_33
// %bb.22:                              //   in Loop: Header=BB2_21 Depth=2
	msub	w12, w22, w17, w4
	cmp	w12, w6
	csel	w0, w12, w6, lt
	cmp	w0, #8
	b.lt	.LBB2_26
// %bb.23:                              //   in Loop: Header=BB2_21 Depth=2
	movi	d2, #0000000000000000
	movi	d16, #0000000000000000
	movi	d7, #0000000000000000
	movi	d6, #0000000000000000
	movi	d5, #0000000000000000
	movi	d4, #0000000000000000
	movi	d3, #0000000000000000
	movi	d1, #0000000000000000
	mov	x1, x9
	mov	x19, x16
	mov	w12, #7                         // =0x7
	.p2align	4, , 8
.LBB2_24:                               //   Parent Loop BB2_9 Depth=1
                                        //     Parent Loop BB2_21 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldurb	w13, [x19, #-3]
	add	x12, x12, #8
	ldurb	w14, [x19, #-2]
	cmp	x12, x0
	ldurb	w15, [x19, #-1]
	lsr	w21, w13, #4
	and	x13, x13, #0xf
	lsl	x13, x13, #3
	and	x17, x14, #0xf
	lsr	w14, w14, #4
	lsr	w2, w15, #4
	ldrb	w20, [x19], #4
	ldr	s19, [x28, x13]
	add	x13, x28, w14, uxtw #3
	and	x14, x15, #0xf
	add	x21, x28, w21, uxtw #3
	lsl	x14, x14, #3
	lsr	w15, w20, #4
	ldr	s23, [x13, #4]
	add	x13, x28, w2, uxtw #3
	ldp	s17, s18, [x1, #-16]
	ldr	s25, [x28, x14]
	and	x14, x20, #0xf
	lsl	x17, x17, #3
	ldr	s26, [x13, #4]
	lsl	x13, x14, #3
	ldr	s21, [x21, #4]
	add	x14, x28, w15, uxtw #3
	fmadd	s2, s19, s17, s2
	ldr	s20, [x28, x17]
	ldp	s22, s24, [x1, #-8]
	ldp	s27, s28, [x1]
	ldr	s29, [x28, x13]
	fmadd	s16, s21, s18, s16
	ldp	s17, s19, [x1, #8]
	ldr	s18, [x14, #4]
	fmadd	s7, s20, s22, s7
	fmadd	s6, s23, s24, s6
	fmadd	s5, s25, s27, s5
	fmadd	s4, s26, s28, s4
	add	x1, x1, #32
	fmadd	s3, s29, s17, s3
	fmadd	s1, s18, s19, s1
	b.lo	.LBB2_24
// %bb.25:                              //   in Loop: Header=BB2_21 Depth=2
	sub	w1, w12, #7
	ldr	x17, [sp, #176]                 // 8-byte Folded Reload
	ldr	x2, [sp, #192]                  // 8-byte Folded Reload
	orr	w12, w1, #0x3
	cmp	w12, w0
	b.lt	.LBB2_27
	b	.LBB2_29
	.p2align	4, , 8
.LBB2_26:                               //   in Loop: Header=BB2_21 Depth=2
	movi	d1, #0000000000000000
	movi	d3, #0000000000000000
	movi	d4, #0000000000000000
	movi	d5, #0000000000000000
	movi	d6, #0000000000000000
	movi	d7, #0000000000000000
	movi	d16, #0000000000000000
	movi	d2, #0000000000000000
	mov	w1, wzr
	orr	w12, wzr, #0x3
	cmp	w12, w0
	b.ge	.LBB2_29
.LBB2_27:                               //   in Loop: Header=BB2_21 Depth=2
	mov	w13, w1
	add	x19, x3, w1, uxtw #2
	add	x14, x13, #2
	add	x12, x13, #3
	add	x13, x27, x13, lsr #1
	add	x21, x27, x14, lsr #1
	.p2align	4, , 8
.LBB2_28:                               //   Parent Loop BB2_9 Depth=1
                                        //     Parent Loop BB2_21 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldrb	w20, [x13], #2
	ldrb	w15, [x21], #2
	ldp	s18, s19, [x19, #-8]
	and	x14, x20, #0xf
	lsr	x20, x20, #1
	lsl	x14, x14, #3
	and	x20, x20, #0x78
	add	x20, x28, x20
	add	x12, x12, #4
	ldp	s22, s23, [x19], #16
	ldr	s17, [x28, x14]
	and	x14, x15, #0xf
	lsr	x15, x15, #1
	lsl	x14, x14, #3
	ldr	s21, [x20, #4]
	add	w1, w1, #4
	cmp	x12, x0
	fmadd	s2, s17, s18, s2
	ldr	s20, [x28, x14]
	and	x14, x15, #0x78
	add	x14, x28, x14
	fmadd	s16, s21, s19, s16
	ldr	s24, [x14, #4]
	fmadd	s7, s20, s22, s7
	fmadd	s6, s24, s23, s6
	b.lo	.LBB2_28
.LBB2_29:                               //   in Loop: Header=BB2_21 Depth=2
	cmp	w1, w0
	b.ge	.LBB2_32
// %bb.30:                              //   in Loop: Header=BB2_21 Depth=2
	ldr	x12, [sp, #184]                 // 8-byte Folded Reload
	mov	w13, w1
	sxtw	x0, w0
	madd	x12, x22, x24, x12
	.p2align	4, , 8
.LBB2_31:                               //   Parent Loop BB2_9 Depth=1
                                        //     Parent Loop BB2_21 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	lsr	w1, w13, #1
	tst	x13, #0x1
	ldr	s18, [x8, x13, lsl #2]
	add	x13, x13, #1
	ldrb	w1, [x12, x1]
	lsr	w19, w1, #4
	and	w1, w1, #0xf
	csel	w1, w1, w19, eq
	cmp	x13, x0
	ldr	s17, [x30, w1, uxtw #2]
	fmadd	s2, s17, s18, s2
	b.lt	.LBB2_31
.LBB2_32:                               //   in Loop: Header=BB2_21 Depth=2
	fadd	s2, s16, s2
	fadd	s6, s6, s7
	fadd	s4, s4, s5
	fadd	s1, s1, s3
	adrp	x12, :got:PIM_E8M0
	ldr	x12, [x12, :got_lo12:PIM_E8M0]
	fadd	s2, s6, s2
	fadd	s1, s1, s4
	fadd	s1, s1, s2
	fadd	s0, s0, s1
	ldr	s1, [x12, x11, lsl #2]
	fmul	s0, s0, s1
.LBB2_33:                               //   in Loop: Header=BB2_21 Depth=2
	orr	x0, x22, #0x1
	ldrb	w11, [x2, x0]
	cmp	x11, #255
	b.eq	.LBB2_20
// %bb.34:                              //   in Loop: Header=BB2_21 Depth=2
	msub	w12, w0, w17, w4
	cmp	w12, w6
	csel	w1, w12, w6, lt
	cmp	w1, #8
	b.lt	.LBB2_38
// %bb.35:                              //   in Loop: Header=BB2_21 Depth=2
	movi	d2, #0000000000000000
	movi	d16, #0000000000000000
	movi	d7, #0000000000000000
	movi	d6, #0000000000000000
	movi	d5, #0000000000000000
	movi	d4, #0000000000000000
	movi	d3, #0000000000000000
	movi	d1, #0000000000000000
	mov	w17, w4
	mov	x19, xzr
	mov	x12, x10
	mov	x21, x25
	.p2align	4, , 8
.LBB2_36:                               //   Parent Loop BB2_9 Depth=1
                                        //     Parent Loop BB2_21 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldurb	w13, [x21, #-3]
	ldurb	w14, [x21, #-2]
	ldurb	w15, [x21, #-1]
	lsr	w4, w13, #4
	and	x13, x13, #0xf
	lsl	x13, x13, #3
	and	x20, x14, #0xf
	lsr	w14, w14, #4
	lsr	w24, w15, #4
	ldrb	w2, [x21], #4
	ldr	s19, [x28, x13]
	add	x13, x28, w14, uxtw #3
	and	x14, x15, #0xf
	add	x4, x28, w4, uxtw #3
	lsl	x14, x14, #3
	lsr	w15, w2, #4
	ldr	s23, [x13, #4]
	add	x13, x28, w24, uxtw #3
	ldp	s17, s18, [x12, #-16]
	ldr	s25, [x28, x14]
	and	x14, x2, #0xf
	lsl	x20, x20, #3
	ldr	s26, [x13, #4]
	lsl	x13, x14, #3
	ldr	s21, [x4, #4]
	add	x14, x28, w15, uxtw #3
	fmadd	s2, s19, s17, s2
	ldr	s20, [x28, x20]
	ldp	s22, s24, [x12, #-8]
	ldp	s27, s28, [x12]
	ldr	s29, [x28, x13]
	fmadd	s16, s21, s18, s16
	ldp	s17, s19, [x12, #8]
	ldr	s18, [x14, #4]
	fmadd	s7, s20, s22, s7
	fmadd	s6, s23, s24, s6
	fmadd	s5, s25, s27, s5
	fmadd	s4, s26, s28, s4
	add	x13, x19, #15
	fmadd	s3, s29, s17, s3
	fmadd	s1, s18, s19, s1
	add	x19, x19, #8
	add	x12, x12, #32
	cmp	x13, x1
	b.lo	.LBB2_36
// %bb.37:                              //   in Loop: Header=BB2_21 Depth=2
	mov	w4, w17
	ldp	x24, x17, [sp, #168]            // 16-byte Folded Reload
	orr	w12, w19, #0x3
	cmp	w12, w1
	b.lt	.LBB2_39
	b	.LBB2_41
	.p2align	4, , 8
.LBB2_38:                               //   in Loop: Header=BB2_21 Depth=2
	movi	d1, #0000000000000000
	movi	d3, #0000000000000000
	movi	d4, #0000000000000000
	movi	d5, #0000000000000000
	movi	d6, #0000000000000000
	movi	d7, #0000000000000000
	movi	d16, #0000000000000000
	movi	d2, #0000000000000000
	mov	w19, wzr
	orr	w12, w19, #0x3
	cmp	w12, w1
	b.ge	.LBB2_41
.LBB2_39:                               //   in Loop: Header=BB2_21 Depth=2
	mov	w13, w19
	add	x20, x5, w19, uxtw #2
	add	x14, x13, #2
	add	x12, x13, #3
	add	x21, x23, x13, lsr #1
	add	x13, x23, x14, lsr #1
	.p2align	4, , 8
.LBB2_40:                               //   Parent Loop BB2_9 Depth=1
                                        //     Parent Loop BB2_21 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldrb	w14, [x21], #2
	ldrb	w15, [x13], #2
	ldp	s18, s19, [x20, #-8]
	and	x2, x14, #0xf
	lsr	x14, x14, #1
	lsl	x2, x2, #3
	and	x14, x14, #0x78
	add	x14, x28, x14
	add	x12, x12, #4
	ldp	s22, s23, [x20], #16
	ldr	s17, [x28, x2]
	and	x2, x15, #0xf
	lsr	x15, x15, #1
	lsl	x2, x2, #3
	and	x15, x15, #0x78
	ldr	s21, [x14, #4]
	add	x14, x28, x15
	fmadd	s2, s17, s18, s2
	add	w19, w19, #4
	ldr	s20, [x28, x2]
	cmp	x12, x1
	ldr	s24, [x14, #4]
	fmadd	s16, s21, s19, s16
	fmadd	s7, s20, s22, s7
	fmadd	s6, s24, s23, s6
	b.lo	.LBB2_40
.LBB2_41:                               //   in Loop: Header=BB2_21 Depth=2
	cmp	w19, w1
	b.ge	.LBB2_18
// %bb.42:                              //   in Loop: Header=BB2_21 Depth=2
	ldp	x12, x2, [sp, #184]             // 16-byte Folded Reload
	mov	w13, w19
	madd	x12, x0, x24, x12
	sxtw	x0, w1
	.p2align	4, , 8
.LBB2_43:                               //   Parent Loop BB2_9 Depth=1
                                        //     Parent Loop BB2_21 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	lsr	w14, w13, #1
	tst	x13, #0x1
	ldr	s18, [x26, x13, lsl #2]
	add	x13, x13, #1
	ldrb	w14, [x12, x14]
	lsr	w15, w14, #4
	and	w14, w14, #0xf
	csel	w14, w14, w15, eq
	cmp	x13, x0
	ldr	s17, [x30, w14, uxtw #2]
	fmadd	s2, s17, s18, s2
	b.lt	.LBB2_43
	b	.LBB2_19
.LBB2_44:                               //   in Loop: Header=BB2_9 Depth=1
	movi	d1, #0000000000000000
	movi	d3, #0000000000000000
	movi	d4, #0000000000000000
	movi	d5, #0000000000000000
	movi	d6, #0000000000000000
	movi	d7, #0000000000000000
	movi	d16, #0000000000000000
	movi	d2, #0000000000000000
	mov	w16, wzr
	orr	w10, w16, #0x3
	cmp	w10, w11
	b.ge	.LBB2_47
.LBB2_45:                               //   in Loop: Header=BB2_9 Depth=1
	ldr	x10, [sp, #16]                  // 8-byte Folded Reload
	mov	w13, w16
	add	x15, x13, #2
	add	x0, x12, x13, lsr #1
	mul	x14, x10, x22
	add	x10, x13, #3
	add	x1, x12, x15, lsr #1
	add	x13, x14, w16, uxtw #2
	ldr	x14, [sp, #48]                  // 8-byte Folded Reload
	add	x13, x14, x13
	.p2align	4, , 8
.LBB2_46:                               //   Parent Loop BB2_9 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldrb	w14, [x27, x0]
	add	x10, x10, #4
	ldrb	w15, [x27, x1]
	add	w16, w16, #4
	ldp	s17, s18, [x13, #-8]
	ldp	s20, s21, [x13], #16
	and	x2, x14, #0xf
	lsl	x2, x2, #3
	lsr	x14, x14, #1
	and	x14, x14, #0x78
	add	x0, x0, #2
	add	x14, x28, x14
	add	x1, x1, #2
	ldr	s19, [x28, x2]
	and	x2, x15, #0xf
	lsr	x15, x15, #1
	lsl	x2, x2, #3
	and	x15, x15, #0x78
	ldr	s23, [x14, #4]
	add	x15, x28, x15
	cmp	x10, x11
	ldr	s22, [x28, x2]
	fmadd	s2, s19, s17, s2
	fmadd	s16, s23, s18, s16
	ldr	s24, [x15, #4]
	fmadd	s7, s22, s20, s7
	fmadd	s6, s24, s21, s6
	b.lo	.LBB2_46
.LBB2_47:                               //   in Loop: Header=BB2_9 Depth=1
	cmp	w16, w11
	b.ge	.LBB2_7
// %bb.48:                              //   in Loop: Header=BB2_9 Depth=1
	ldr	x10, [sp, #184]                 // 8-byte Folded Reload
	sxtw	x11, w11
	add	x10, x10, x12
	ldr	x12, [sp, #64]                  // 8-byte Folded Reload
	add	x9, x12, x9, lsl #2
	mov	w12, w16
	.p2align	4, , 8
.LBB2_49:                               //   Parent Loop BB2_9 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	lsr	w13, w12, #1
	tst	x12, #0x1
	ldr	s18, [x9, x12, lsl #2]
	add	x12, x12, #1
	ldrb	w13, [x10, x13]
	lsr	w14, w13, #4
	and	w13, w13, #0xf
	csel	w13, w13, w14, eq
	cmp	x12, x11
	ldr	s17, [x30, w13, uxtw #2]
	fmadd	s2, s17, s18, s2
	b.lt	.LBB2_49
	b	.LBB2_7
.LBB2_50:
	ldp	x20, x19, [sp, #288]            // 16-byte Folded Reload
	ldp	x22, x21, [sp, #272]            // 16-byte Folded Reload
	ldp	x24, x23, [sp, #256]            // 16-byte Folded Reload
	ldp	x26, x25, [sp, #240]            // 16-byte Folded Reload
	ldp	x28, x27, [sp, #224]            // 16-byte Folded Reload
	ldr	x30, [sp, #208]                 // 8-byte Folded Reload
	add	sp, sp, #304
	.cfi_def_cfa_offset 0
	.cfi_restore w19
	.cfi_restore w20
	.cfi_restore w21
	.cfi_restore w22
	.cfi_restore w23
	.cfi_restore w24
	.cfi_restore w25
	.cfi_restore w26
	.cfi_restore w27
	.cfi_restore w28
	.cfi_restore w30
	ret
.LBB2_51:
	.cfi_restore_state
	ldp	x20, x19, [sp, #288]            // 16-byte Folded Reload
	lsl	x2, x5, #2
	mov	w1, wzr
	ldp	x22, x21, [sp, #272]            // 16-byte Folded Reload
	ldp	x24, x23, [sp, #256]            // 16-byte Folded Reload
	ldp	x26, x25, [sp, #240]            // 16-byte Folded Reload
	ldp	x28, x27, [sp, #224]            // 16-byte Folded Reload
	ldr	x0, [sp, #112]                  // 8-byte Folded Reload
	ldr	x30, [sp, #208]                 // 8-byte Folded Reload
	add	sp, sp, #304
	.cfi_def_cfa_offset 0
	.cfi_restore w19
	.cfi_restore w20
	.cfi_restore w21
	.cfi_restore w22
	.cfi_restore w23
	.cfi_restore w24
	.cfi_restore w25
	.cfi_restore w26
	.cfi_restore w27
	.cfi_restore w28
	.cfi_restore w30
	b	memset
.Lfunc_end2:
	.size	pim_mxfp4_gemv_opt_v3, .Lfunc_end2-pim_mxfp4_gemv_opt_v3
	.cfi_endproc
                                        // -- End function
	.globl	pim_mxfp4_gemv_opt_v4           // -- Begin function pim_mxfp4_gemv_opt_v4
	.p2align	4
	.type	pim_mxfp4_gemv_opt_v4,@function
pim_mxfp4_gemv_opt_v4:                  // @pim_mxfp4_gemv_opt_v4
	.cfi_startproc
// %bb.0:
	sub	sp, sp, #240
	.cfi_def_cfa_offset 240
	str	x30, [sp, #144]                 // 8-byte Folded Spill
	stp	x28, x27, [sp, #160]            // 16-byte Folded Spill
	stp	x26, x25, [sp, #176]            // 16-byte Folded Spill
	stp	x24, x23, [sp, #192]            // 16-byte Folded Spill
	stp	x22, x21, [sp, #208]            // 16-byte Folded Spill
	stp	x20, x19, [sp, #224]            // 16-byte Folded Spill
	.cfi_offset w19, -8
	.cfi_offset w20, -16
	.cfi_offset w21, -24
	.cfi_offset w22, -32
	.cfi_offset w23, -40
	.cfi_offset w24, -48
	.cfi_offset w25, -56
	.cfi_offset w26, -64
	.cfi_offset w27, -72
	.cfi_offset w28, -80
	.cfi_offset w30, -96
	.cfi_remember_state
	cmp	w5, #1
                                        // kill: def $w6 killed $w6 def $x6
	stp	x3, x0, [sp, #56]               // 16-byte Folded Spill
	str	x2, [sp, #72]                   // 8-byte Folded Spill
	str	x1, [sp, #16]                   // 8-byte Folded Spill
	b.lt	.LBB3_45
// %bb.1:
	add	w8, w4, w6
	mov	w19, w5
	sub	w8, w8, #1
	sdiv	w20, w8, w6
	cmp	w20, #0
	b.le	.LBB3_46
// %bb.2:
	add	w8, w4, w4, lsr #31
	sxtw	x14, w6
	sbfx	x22, x8, #1, #31
	sxtw	x8, w20
	lsl	x10, x14, #2
	ldr	x2, [sp, #72]                   // 8-byte Folded Reload
	add	w9, w6, w6, lsr #31
	mov	x21, xzr
	str	x8, [sp, #24]                   // 8-byte Folded Spill
	and	x8, x20, #0x7ffffffe
	sbfx	x9, x9, #1, #31
	add	x5, x2, #1
	add	x24, x2, x9
	str	x10, [sp, #128]                 // 8-byte Folded Spill
	str	x8, [sp, #152]                  // 8-byte Folded Spill
	ldr	x8, [sp, #16]                   // 8-byte Folded Reload
	movi	v0.2d, #0000000000000000
	lsl	x17, x14, #3
	lsl	x7, x9, #1
	add	x25, x24, #3
	add	x8, x8, #16
	adrp	x26, PIM_E2M1
	add	x26, x26, :lo12:PIM_E2M1
	str	x8, [sp, #8]                    // 8-byte Folded Spill
	add	x8, x8, x10
	str	x8, [sp]                        // 8-byte Folded Spill
	adrp	x27, :got:PIM_E8M0
	ldr	x27, [x27, :got_lo12:PIM_E8M0]
	add	x8, x5, x9
	stp	x20, x19, [sp, #40]             // 16-byte Folded Spill
	str	x22, [sp, #32]                  // 8-byte Folded Spill
	stp	x8, x9, [sp, #112]              // 16-byte Folded Spill
	b	.LBB3_5
	.p2align	4, , 8
.LBB3_3:                                //   in Loop: Header=BB3_5 Depth=1
	ldr	s3, [x27, x8, lsl #2]
	fmul	v1.4s, v1.4s, v3.s[0]
.LBB3_4:                                //   in Loop: Header=BB3_5 Depth=1
	fadd	v1.4s, v2.4s, v1.4s
	ldr	x8, [sp, #64]                   // 8-byte Folded Reload
	add	x5, x5, x22
	add	x2, x2, x22
	add	x25, x25, x22
	add	x24, x24, x22
	fadd	v1.4s, v1.4s, v0.4s
	dup	v2.4s, v1.s[1]
	dup	v3.4s, v1.s[2]
	fadd	v2.4s, v1.4s, v2.4s
	dup	v1.4s, v1.s[3]
	fadd	v2.4s, v3.4s, v2.4s
	fadd	v1.4s, v1.4s, v2.4s
	str	s1, [x8, x21, lsl #2]
	ldr	x8, [sp, #112]                  // 8-byte Folded Reload
	add	x21, x21, #1
	cmp	x21, x19
	add	x8, x8, x22
	str	x8, [sp, #112]                  // 8-byte Folded Spill
	b.eq	.LBB3_45
.LBB3_5:                                // =>This Loop Header: Depth=1
                                        //     Child Loop BB3_16 Depth 2
                                        //       Child Loop BB3_19 Depth 3
                                        //       Child Loop BB3_23 Depth 3
                                        //       Child Loop BB3_26 Depth 3
                                        //       Child Loop BB3_31 Depth 3
                                        //       Child Loop BB3_35 Depth 3
                                        //       Child Loop BB3_38 Depth 3
                                        //     Child Loop BB3_11 Depth 2
                                        //     Child Loop BB3_41 Depth 2
                                        //     Child Loop BB3_44 Depth 2
	ldr	x8, [sp, #72]                   // 8-byte Folded Reload
	cmp	w20, #1
	ldr	x9, [sp, #24]                   // 8-byte Folded Reload
	stp	x5, x21, [sp, #96]              // 16-byte Folded Spill
	stp	x25, x24, [sp, #80]             // 16-byte Folded Spill
	nop
	madd	x8, x21, x22, x8
	str	x8, [sp, #136]                  // 8-byte Folded Spill
	ldr	x8, [sp, #56]                   // 8-byte Folded Reload
	nop
	madd	x30, x21, x9, x8
	b.ne	.LBB3_13
// %bb.6:                               //   in Loop: Header=BB3_5 Depth=1
	movi	v1.2d, #0000000000000000
	mov	x28, xzr
	movi	v2.2d, #0000000000000000
.LBB3_7:                                //   in Loop: Header=BB3_5 Depth=1
	ldp	x20, x19, [sp, #40]             // 16-byte Folded Reload
	ldp	x5, x21, [sp, #96]              // 16-byte Folded Reload
	ldp	x25, x24, [sp, #80]             // 16-byte Folded Reload
	ldr	x22, [sp, #32]                  // 8-byte Folded Reload
	tbz	w20, #0, .LBB3_4
// %bb.8:                               //   in Loop: Header=BB3_5 Depth=1
	ldrb	w8, [x30, x28]
	cmp	x8, #255
	b.eq	.LBB3_4
// %bb.9:                               //   in Loop: Header=BB3_5 Depth=1
	ldr	x10, [sp, #120]                 // 8-byte Folded Reload
	msub	w9, w28, w14, w4
	cmp	w9, w6
	mul	x11, x28, x10
	csel	w9, w9, w6, lt
	cmp	w9, #8
	b.lt	.LBB3_39
// %bb.10:                              //   in Loop: Header=BB3_5 Depth=1
	ldr	x10, [sp, #8]                   // 8-byte Folded Reload
	mov	x23, x5
	ldr	x13, [sp, #128]                 // 8-byte Folded Reload
	mov	x12, xzr
	mov	x16, x11
	madd	x0, x13, x28, x10
	.p2align	4, , 8
.LBB3_11:                               //   Parent Loop BB3_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	add	x10, x2, x16
	add	x16, x16, #4
	ldp	q5, q6, [x0, #-16]
	add	x0, x0, #32
	ldrb	w13, [x10]
	ldrb	w15, [x10, #2]
	ldrb	w3, [x10, #1]
	and	x1, x13, #0xf
	lsr	x13, x13, #4
	and	x5, x15, #0xf
	lsr	x15, x15, #4
	ldrb	w10, [x10, #3]
	add	x13, x26, x13, lsl #2
	ldr	s3, [x26, x1, lsl #2]
	add	x15, x26, x15, lsl #2
	ldr	s4, [x26, x5, lsl #2]
	and	x1, x3, #0xf
	and	x5, x10, #0xf
	lsr	x10, x10, #4
	ld1	{ v3.s }[1], [x13]
	add	x13, x26, x1, lsl #2
	ld1	{ v4.s }[1], [x15]
	add	x15, x26, x5, lsl #2
	lsr	x1, x3, #4
	add	x10, x26, x10, lsl #2
	ld1	{ v3.s }[2], [x13]
	add	x13, x26, x1, lsl #2
	ld1	{ v4.s }[2], [x15]
	ld1	{ v3.s }[3], [x13]
	ld1	{ v4.s }[3], [x10]
	add	x10, x12, #15
	add	x12, x12, #8
	cmp	x10, x9
	fmla	v1.4s, v3.4s, v5.4s
	fmla	v2.4s, v4.4s, v6.4s
	b.lo	.LBB3_11
// %bb.12:                              //   in Loop: Header=BB3_5 Depth=1
	mov	x5, x23
	orr	w10, w12, #0x3
	cmp	w10, w9
	b.lt	.LBB3_40
	b	.LBB3_42
	.p2align	4, , 8
.LBB3_13:                               //   in Loop: Header=BB3_5 Depth=1
	ldp	x16, x9, [sp]                   // 16-byte Folded Reload
	movi	v1.2d, #0000000000000000
	mov	x28, xzr
	movi	v2.2d, #0000000000000000
	mov	x19, x24
	ldr	x24, [sp, #112]                 // 8-byte Folded Reload
	mov	x10, x25
	mov	x25, x2
	ldr	x8, [sp, #16]                   // 8-byte Folded Reload
	b	.LBB3_16
	.p2align	4, , 8
.LBB3_14:                               //   in Loop: Header=BB3_16 Depth=2
	ldr	s3, [x27, x0, lsl #2]
	fmul	v1.4s, v1.4s, v3.s[0]
.LBB3_15:                               //   in Loop: Header=BB3_16 Depth=2
	ldr	x11, [sp, #152]                 // 8-byte Folded Reload
	add	x28, x28, #2
	add	x9, x9, x17
	add	x5, x5, x7
	add	x8, x8, x17
	add	x25, x25, x7
	add	x10, x10, x7
	add	x16, x16, x17
	add	x24, x24, x7
	add	x19, x19, x7
	cmp	x28, x11
	b.eq	.LBB3_7
.LBB3_16:                               //   Parent Loop BB3_5 Depth=1
                                        // =>  This Loop Header: Depth=2
                                        //       Child Loop BB3_19 Depth 3
                                        //       Child Loop BB3_23 Depth 3
                                        //       Child Loop BB3_26 Depth 3
                                        //       Child Loop BB3_31 Depth 3
                                        //       Child Loop BB3_35 Depth 3
                                        //       Child Loop BB3_38 Depth 3
	ldrb	w0, [x30, x28]
	cmp	x0, #255
	b.eq	.LBB3_28
// %bb.17:                              //   in Loop: Header=BB3_16 Depth=2
	msub	w11, w28, w14, w4
	cmp	w11, w6
	csel	w11, w11, w6, lt
	cmp	w11, #8
	b.lt	.LBB3_21
// %bb.18:                              //   in Loop: Header=BB3_16 Depth=2
	mov	x1, x5
	mov	x21, x9
	mov	w12, #7                         // =0x7
	.p2align	4, , 8
.LBB3_19:                               //   Parent Loop BB3_5 Depth=1
                                        //     Parent Loop BB3_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldurb	w13, [x1, #-1]
	add	x12, x12, #8
	ldrb	w20, [x1, #1]
	cmp	x12, x11
	ldrb	w23, [x1]
	and	x22, x13, #0xf
	lsr	x13, x13, #4
	and	x3, x20, #0xf
	lsr	x20, x20, #4
	ldrb	w27, [x1, #2]
	add	x13, x26, x13, lsl #2
	ldr	s3, [x26, x22, lsl #2]
	add	x1, x1, #4
	ldr	s4, [x26, x3, lsl #2]
	add	x3, x26, x20, lsl #2
	and	x20, x23, #0xf
	and	x22, x27, #0xf
	ldp	q5, q6, [x21, #-16]
	add	x21, x21, #32
	ld1	{ v3.s }[1], [x13]
	add	x13, x26, x20, lsl #2
	ld1	{ v4.s }[1], [x3]
	add	x3, x26, x22, lsl #2
	lsr	x20, x23, #4
	lsr	x22, x27, #4
	ld1	{ v3.s }[2], [x13]
	add	x13, x26, x20, lsl #2
	ld1	{ v4.s }[2], [x3]
	add	x3, x26, x22, lsl #2
	ld1	{ v3.s }[3], [x13]
	ld1	{ v4.s }[3], [x3]
	fmla	v1.4s, v3.4s, v5.4s
	fmla	v2.4s, v4.4s, v6.4s
	b.lo	.LBB3_19
// %bb.20:                              //   in Loop: Header=BB3_16 Depth=2
	sub	w1, w12, #7
	adrp	x27, :got:PIM_E8M0
	ldr	x27, [x27, :got_lo12:PIM_E8M0]
	orr	w12, w1, #0x3
	cmp	w12, w11
	b.lt	.LBB3_22
	b	.LBB3_24
	.p2align	4, , 8
.LBB3_21:                               //   in Loop: Header=BB3_16 Depth=2
	mov	w1, wzr
	orr	w12, w1, #0x3
	cmp	w12, w11
	b.ge	.LBB3_24
.LBB3_22:                               //   in Loop: Header=BB3_16 Depth=2
	mov	w15, w1
	add	x12, x8, w1, uxtw #2
	lsr	x13, x15, #1
	add	x21, x15, #3
	.p2align	4, , 8
.LBB3_23:                               //   Parent Loop BB3_5 Depth=1
                                        //     Parent Loop BB3_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldrb	w22, [x25, x13]
	add	w1, w1, #4
	ldrb	w20, [x5, x13]
	add	x13, x13, #2
	ldr	q4, [x12], #16
	add	x21, x21, #4
	and	x23, x22, #0xf
	lsr	x22, x22, #4
	cmp	x21, x11
	add	x22, x26, x22, lsl #2
	ldr	s3, [x26, x23, lsl #2]
	and	x23, x20, #0xf
	lsr	x20, x20, #4
	add	x20, x26, x20, lsl #2
	ld1	{ v3.s }[1], [x22]
	add	x22, x26, x23, lsl #2
	ld1	{ v3.s }[2], [x22]
	ld1	{ v3.s }[3], [x20]
	fmla	v1.4s, v3.4s, v4.4s
	b.lo	.LBB3_23
.LBB3_24:                               //   in Loop: Header=BB3_16 Depth=2
	cmp	w1, w11
	b.ge	.LBB3_27
// %bb.25:                              //   in Loop: Header=BB3_16 Depth=2
	ldr	x12, [sp, #120]                 // 8-byte Folded Reload
	sxtw	x11, w11
	ldr	x13, [sp, #136]                 // 8-byte Folded Reload
	nop
	madd	x12, x28, x12, x13
	mov	w13, w1
	ubfiz	x1, x1, #2, #32
	.p2align	4, , 8
.LBB3_26:                               //   Parent Loop BB3_5 Depth=1
                                        //     Parent Loop BB3_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	lsr	w21, w13, #1
	tst	x13, #0x1
	ldr	q4, [x8, x1]
	add	x13, x13, #1
	add	x1, x1, #4
	ldrb	w21, [x12, x21]
	lsr	w22, w21, #4
	and	w21, w21, #0xf
	csel	w21, w21, w22, eq
	cmp	x13, x11
	ldr	s3, [x26, w21, uxtw #2]
	fmla	v1.4s, v4.4s, v3.s[0]
	b.lt	.LBB3_26
.LBB3_27:                               //   in Loop: Header=BB3_16 Depth=2
	ldr	s3, [x27, x0, lsl #2]
	fmul	v1.4s, v1.4s, v3.s[0]
.LBB3_28:                               //   in Loop: Header=BB3_16 Depth=2
	orr	x11, x28, #0x1
	ldrb	w0, [x30, x11]
	cmp	x0, #255
	b.eq	.LBB3_15
// %bb.29:                              //   in Loop: Header=BB3_16 Depth=2
	msub	w12, w11, w14, w4
	cmp	w12, w6
	csel	w1, w12, w6, lt
	cmp	w1, #8
	b.lt	.LBB3_33
// %bb.30:                              //   in Loop: Header=BB3_16 Depth=2
	mov	x22, xzr
	mov	x12, x16
	mov	x21, x10
	.p2align	4, , 8
.LBB3_31:                               //   Parent Loop BB3_5 Depth=1
                                        //     Parent Loop BB3_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldurb	w13, [x21, #-3]
	ldurb	w3, [x21, #-1]
	ldurb	w23, [x21, #-2]
	and	x20, x13, #0xf
	lsr	x13, x13, #4
	and	x27, x3, #0xf
	lsr	x3, x3, #4
	ldrb	w15, [x21], #4
	ldr	s3, [x26, x20, lsl #2]
	add	x13, x26, x13, lsl #2
	ldr	s4, [x26, x27, lsl #2]
	add	x3, x26, x3, lsl #2
	and	x20, x23, #0xf
	and	x27, x15, #0xf
	lsr	x15, x15, #4
	ld1	{ v3.s }[1], [x13]
	add	x13, x26, x20, lsl #2
	ld1	{ v4.s }[1], [x3]
	add	x3, x26, x27, lsl #2
	lsr	x20, x23, #4
	add	x15, x26, x15, lsl #2
	ldp	q5, q6, [x12, #-16]
	add	x12, x12, #32
	ld1	{ v3.s }[2], [x13]
	add	x13, x26, x20, lsl #2
	ld1	{ v4.s }[2], [x3]
	ld1	{ v3.s }[3], [x13]
	add	x13, x22, #15
	ld1	{ v4.s }[3], [x15]
	add	x22, x22, #8
	cmp	x13, x1
	fmla	v1.4s, v3.4s, v5.4s
	fmla	v2.4s, v4.4s, v6.4s
	b.lo	.LBB3_31
// %bb.32:                              //   in Loop: Header=BB3_16 Depth=2
	adrp	x27, :got:PIM_E8M0
	ldr	x27, [x27, :got_lo12:PIM_E8M0]
	orr	w12, w22, #0x3
	cmp	w12, w1
	b.lt	.LBB3_34
	b	.LBB3_36
	.p2align	4, , 8
.LBB3_33:                               //   in Loop: Header=BB3_16 Depth=2
	mov	w22, wzr
	orr	w12, w22, #0x3
	cmp	w12, w1
	b.ge	.LBB3_36
.LBB3_34:                               //   in Loop: Header=BB3_16 Depth=2
	ldr	x15, [sp, #128]                 // 8-byte Folded Reload
	mov	w13, w22
	add	x12, x13, #3
	add	x21, x15, w22, uxtw #2
	lsr	x15, x13, #1
	add	x13, x24, x15
	add	x23, x19, x15
	.p2align	4, , 8
.LBB3_35:                               //   Parent Loop BB3_5 Depth=1
                                        //     Parent Loop BB3_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldrb	w15, [x23], #2
	ldrb	w20, [x13], #2
	ldr	q4, [x8, x21]
	add	w22, w22, #4
	and	x3, x15, #0xf
	lsr	x15, x15, #4
	add	x12, x12, #4
	add	x21, x21, #16
	add	x15, x26, x15, lsl #2
	cmp	x12, x1
	ldr	s3, [x26, x3, lsl #2]
	and	x3, x20, #0xf
	ld1	{ v3.s }[1], [x15]
	add	x15, x26, x3, lsl #2
	lsr	x3, x20, #4
	ld1	{ v3.s }[2], [x15]
	add	x15, x26, x3, lsl #2
	ld1	{ v3.s }[3], [x15]
	fmla	v1.4s, v3.4s, v4.4s
	b.lo	.LBB3_35
.LBB3_36:                               //   in Loop: Header=BB3_16 Depth=2
	cmp	w22, w1
	b.ge	.LBB3_14
// %bb.37:                              //   in Loop: Header=BB3_16 Depth=2
	ldp	x12, x15, [sp, #120]            // 16-byte Folded Reload
	ldr	x13, [sp, #136]                 // 8-byte Folded Reload
	nop
	madd	x11, x11, x12, x13
	mov	w12, w22
	sxtw	x13, w1
	add	x1, x15, w22, uxtw #2
	.p2align	4, , 8
.LBB3_38:                               //   Parent Loop BB3_5 Depth=1
                                        //     Parent Loop BB3_16 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	lsr	w15, w12, #1
	tst	x12, #0x1
	ldr	q4, [x8, x1]
	add	x12, x12, #1
	add	x1, x1, #4
	ldrb	w15, [x11, x15]
	lsr	w3, w15, #4
	and	w15, w15, #0xf
	csel	w15, w15, w3, eq
	cmp	x12, x13
	ldr	s3, [x26, w15, uxtw #2]
	fmla	v1.4s, v4.4s, v3.s[0]
	b.lt	.LBB3_38
	b	.LBB3_14
.LBB3_39:                               //   in Loop: Header=BB3_5 Depth=1
	mov	w12, wzr
	orr	w10, w12, #0x3
	cmp	w10, w9
	b.ge	.LBB3_42
.LBB3_40:                               //   in Loop: Header=BB3_5 Depth=1
	ldr	x10, [sp, #128]                 // 8-byte Folded Reload
	mov	w15, w12
	ldr	x16, [sp, #16]                  // 8-byte Folded Reload
	mul	x13, x10, x28
	add	x10, x15, #3
	add	x13, x13, w12, uxtw #2
	add	x13, x16, x13
	add	x16, x11, x15, lsr #1
	.p2align	4, , 8
.LBB3_41:                               //   Parent Loop BB3_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldrb	w15, [x2, x16]
	add	w12, w12, #4
	ldrb	w1, [x5, x16]
	add	x10, x10, #4
	ldr	q4, [x13], #16
	add	x16, x16, #2
	cmp	x10, x9
	and	x0, x15, #0xf
	lsr	x15, x15, #4
	add	x15, x26, x15, lsl #2
	ldr	s3, [x26, x0, lsl #2]
	and	x0, x1, #0xf
	ld1	{ v3.s }[1], [x15]
	add	x15, x26, x0, lsl #2
	lsr	x0, x1, #4
	ld1	{ v3.s }[2], [x15]
	add	x15, x26, x0, lsl #2
	ld1	{ v3.s }[3], [x15]
	fmla	v1.4s, v3.4s, v4.4s
	b.lo	.LBB3_41
.LBB3_42:                               //   in Loop: Header=BB3_5 Depth=1
	cmp	w12, w9
	b.ge	.LBB3_3
// %bb.43:                              //   in Loop: Header=BB3_5 Depth=1
	ldr	x10, [sp, #128]                 // 8-byte Folded Reload
	sxtw	x9, w9
	mul	x13, x10, x28
	ldr	x10, [sp, #136]                 // 8-byte Folded Reload
	add	x10, x10, x11
	mov	w11, w12
	add	x12, x13, w12, uxtw #2
	ldr	x13, [sp, #16]                  // 8-byte Folded Reload
	add	x12, x13, x12
	.p2align	4, , 8
.LBB3_44:                               //   Parent Loop BB3_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	lsr	w13, w11, #1
	tst	x11, #0x1
	ldr	q4, [x12], #4
	add	x11, x11, #1
	ldrb	w13, [x10, x13]
	lsr	w15, w13, #4
	and	w13, w13, #0xf
	csel	w13, w13, w15, eq
	cmp	x11, x9
	ldr	s3, [x26, w13, uxtw #2]
	fmla	v1.4s, v4.4s, v3.s[0]
	b.lt	.LBB3_44
	b	.LBB3_3
.LBB3_45:
	ldp	x20, x19, [sp, #224]            // 16-byte Folded Reload
	ldp	x22, x21, [sp, #208]            // 16-byte Folded Reload
	ldp	x24, x23, [sp, #192]            // 16-byte Folded Reload
	ldp	x26, x25, [sp, #176]            // 16-byte Folded Reload
	ldp	x28, x27, [sp, #160]            // 16-byte Folded Reload
	ldr	x30, [sp, #144]                 // 8-byte Folded Reload
	add	sp, sp, #240
	.cfi_def_cfa_offset 0
	.cfi_restore w19
	.cfi_restore w20
	.cfi_restore w21
	.cfi_restore w22
	.cfi_restore w23
	.cfi_restore w24
	.cfi_restore w25
	.cfi_restore w26
	.cfi_restore w27
	.cfi_restore w28
	.cfi_restore w30
	ret
.LBB3_46:
	.cfi_restore_state
	lsl	x2, x19, #2
	ldr	x0, [sp, #64]                   // 8-byte Folded Reload
	ldp	x20, x19, [sp, #224]            // 16-byte Folded Reload
	mov	w1, wzr
	ldp	x22, x21, [sp, #208]            // 16-byte Folded Reload
	ldp	x24, x23, [sp, #192]            // 16-byte Folded Reload
	ldp	x26, x25, [sp, #176]            // 16-byte Folded Reload
	ldp	x28, x27, [sp, #160]            // 16-byte Folded Reload
	ldr	x30, [sp, #144]                 // 8-byte Folded Reload
	add	sp, sp, #240
	.cfi_def_cfa_offset 0
	.cfi_restore w19
	.cfi_restore w20
	.cfi_restore w21
	.cfi_restore w22
	.cfi_restore w23
	.cfi_restore w24
	.cfi_restore w25
	.cfi_restore w26
	.cfi_restore w27
	.cfi_restore w28
	.cfi_restore w30
	b	memset
.Lfunc_end3:
	.size	pim_mxfp4_gemv_opt_v4, .Lfunc_end3-pim_mxfp4_gemv_opt_v4
	.cfi_endproc
                                        // -- End function
	.section	.rodata.cst16,"aM",@progbits,16
	.p2align	4, 0x0                          // -- Begin function main
.LCPI4_0:
	.word	0                               // 0x0
	.word	1                               // 0x1
	.word	2                               // 0x2
	.word	3                               // 0x3
.LCPI4_1:
	.byte	0                               // 0x0
	.byte	1                               // 0x1
	.byte	2                               // 0x2
	.byte	3                               // 0x3
	.byte	4                               // 0x4
	.byte	5                               // 0x5
	.byte	6                               // 0x6
	.byte	7                               // 0x7
	.byte	8                               // 0x8
	.byte	9                               // 0x9
	.byte	10                              // 0xa
	.byte	11                              // 0xb
	.byte	12                              // 0xc
	.byte	13                              // 0xd
	.byte	14                              // 0xe
	.byte	15                              // 0xf
	.section	.rodata.cst8,"aM",@progbits,8
	.p2align	3, 0x0
.LCPI4_2:
	.xword	0x3f70624dd2f1a9fc              // double 0.0040000000000000001
.LCPI4_3:
	.word	3584                            // 0xe00
	.word	32                              // 0x20
	.text
	.globl	main
	.p2align	4
	.type	main,@function
main:                                   // @main
	.cfi_startproc
// %bb.0:
	stp	d15, d14, [sp, #-160]!          // 16-byte Folded Spill
	.cfi_def_cfa_offset 160
	stp	d13, d12, [sp, #16]             // 16-byte Folded Spill
	stp	d11, d10, [sp, #32]             // 16-byte Folded Spill
	stp	d9, d8, [sp, #48]               // 16-byte Folded Spill
	stp	x29, x30, [sp, #64]             // 16-byte Folded Spill
	stp	x28, x27, [sp, #80]             // 16-byte Folded Spill
	stp	x26, x25, [sp, #96]             // 16-byte Folded Spill
	stp	x24, x23, [sp, #112]            // 16-byte Folded Spill
	stp	x22, x21, [sp, #128]            // 16-byte Folded Spill
	stp	x20, x19, [sp, #144]            // 16-byte Folded Spill
	add	x29, sp, #64
	.cfi_def_cfa w29, 96
	.cfi_offset w19, -8
	.cfi_offset w20, -16
	.cfi_offset w21, -24
	.cfi_offset w22, -32
	.cfi_offset w23, -40
	.cfi_offset w24, -48
	.cfi_offset w25, -56
	.cfi_offset w26, -64
	.cfi_offset w27, -72
	.cfi_offset w28, -80
	.cfi_offset w30, -88
	.cfi_offset w29, -96
	.cfi_offset b8, -104
	.cfi_offset b9, -112
	.cfi_offset b10, -120
	.cfi_offset b11, -128
	.cfi_offset b12, -136
	.cfi_offset b13, -144
	.cfi_offset b14, -152
	.cfi_offset b15, -160
	.cfi_remember_state
	sub	sp, sp, #1392
	cmp	w0, #2
	b.lt	.LBB4_2
// %bb.1:
	ldr	x0, [x1, #8]
	bl	atoi
	mov	w27, w0
	b	.LBB4_3
.LBB4_2:
	mov	w27, #200                       // =0xc8
.LBB4_3:
	adrp	x0, .L.str.3
	add	x0, x0, :lo12:.L.str.3
	mov	w1, w27
	bl	printf
	adrp	x0, .Lstr
	add	x0, x0, :lo12:.Lstr
	bl	puts
	mov	x9, #4562146422526312448        // =0x3f50000000000000
	mov	x8, #4660099714421620736        // =0x40ac000000000000
	scvtf	d0, w27
	mov	w10, #63736                     // =0xf8f8
	movk	w10, #22410, lsl #16
	mov	w11, #19923                     // =0x4dd3
	fmov	d14, x9
	mov	w9, #4660                       // =0x1234
	movk	w9, #57005, lsl #16
	str	x8, [sp, #136]                  // 8-byte Folded Spill
	adrp	x8, .LCPI4_0
	ldr	q1, [x8, :lo12:.LCPI4_0]
	str	d0, [sp, #72]                   // 8-byte Folded Spill
	mov	w8, #31153                      // =0x79b1
	dup	v0.4s, w9
	movk	w8, #40503, lsl #16
	movk	w11, #4194, lsl #16
	mov	w13, #55050                     // =0xd70a
	stp	q0, q1, [sp, #96]               // 32-byte Folded Spill
	dup	v0.4s, w10
	mov	w12, #1000                      // =0x3e8
	movk	w13, #15395, lsl #16
	dup	v2.4s, w8
	str	q0, [sp, #80]                   // 16-byte Folded Spill
	dup	v0.4s, w11
	mov	x8, #54933                      // =0xd695
	dup	v1.4s, w12
	movk	x8, #59430, lsl #16
	stp	q0, q2, [sp, #224]              // 32-byte Folded Spill
	dup	v0.4s, w13
	movk	x8, #11787, lsl #32
	adrp	x9, .LCPI4_1
	stp	q0, q1, [sp, #192]              // 32-byte Folded Spill
	movk	x8, #15889, lsl #48
	ldr	q0, [x9, :lo12:.LCPI4_1]
	mov	x21, xzr
	str	w27, [sp, #268]                 // 4-byte Folded Spill
	str	q0, [sp, #176]                  // 16-byte Folded Spill
	dup	v0.2d, x8
	adrp	x8, .LCPI4_2
	ldr	d13, [x8, :lo12:.LCPI4_2]
	str	q0, [sp, #144]                  // 16-byte Folded Spill
	b	.LBB4_5
	.p2align	4, , 8
.LBB4_4:                                //   in Loop: Header=BB4_5 Depth=1
	mov	w0, #10                         // =0xa
	bl	putchar
	add	x21, x21, #1
	cmp	x21, #3
	b.eq	.LBB4_73
.LBB4_5:                                // =>This Loop Header: Depth=1
                                        //     Child Loop BB4_10 Depth 2
                                        //     Child Loop BB4_12 Depth 2
                                        //     Child Loop BB4_14 Depth 2
                                        //     Child Loop BB4_17 Depth 2
                                        //     Child Loop BB4_19 Depth 2
                                        //     Child Loop BB4_21 Depth 2
                                        //     Child Loop BB4_27 Depth 2
                                        //     Child Loop BB4_29 Depth 2
                                        //     Child Loop BB4_32 Depth 2
                                        //     Child Loop BB4_34 Depth 2
                                        //     Child Loop BB4_36 Depth 2
                                        //     Child Loop BB4_38 Depth 2
                                        //     Child Loop BB4_40 Depth 2
                                        //     Child Loop BB4_42 Depth 2
                                        //     Child Loop BB4_44 Depth 2
                                        //     Child Loop BB4_46 Depth 2
                                        //     Child Loop BB4_48 Depth 2
                                        //     Child Loop BB4_50 Depth 2
                                        //     Child Loop BB4_52 Depth 2
                                        //     Child Loop BB4_54 Depth 2
                                        //     Child Loop BB4_56 Depth 2
                                        //     Child Loop BB4_58 Depth 2
                                        //     Child Loop BB4_60 Depth 2
                                        //     Child Loop BB4_63 Depth 2
                                        //       Child Loop BB4_64 Depth 3
                                        //       Child Loop BB4_66 Depth 3
                                        //     Child Loop BB4_69 Depth 2
	adrp	x8, .L__const.main.batch
	add	x8, x8, :lo12:.L__const.main.batch
	ldr	d0, [sp, #136]                  // 8-byte Folded Reload
	fmov	d1, #0.50000000
	ldrsw	x19, [x8, x21, lsl #2]
	adrp	x9, .L__const.main.bname.rel
	add	x9, x9, :lo12:.L__const.main.bname.rel
	adrp	x0, .L.str.5
	add	x0, x0, :lo12:.L.str.5
	mov	w2, #64                         // =0x40
	ldrsw	x8, [x9, x21, lsl #2]
	mov	w3, #3584                       // =0xe00
	lsl	w23, w19, #6
	mov	w4, w23
	scvtf	d8, w23
	add	x1, x9, x8
	fmul	d0, d8, d0
	fmul	d0, d0, d1
	fmul	d0, d0, d14
	bl	printf
	mov	w0, #14336                      // =0x3800
	bl	malloc
	mov	x26, x0
	lsl	x0, x19, #8
	mov	x22, x0
	bl	malloc
	lsl	x8, x19, #17
	mov	x24, x0
	sub	x20, x8, x19, lsl #14
	mov	x0, x20
	bl	malloc
	lsl	x8, x19, #13
	mov	x28, x0
	sub	x19, x8, x19, lsl #10
	mov	x0, x19
	bl	malloc
	cbz	x26, .LBB4_94
// %bb.6:                               //   in Loop: Header=BB4_5 Depth=1
	cbz	x24, .LBB4_94
// %bb.7:                               //   in Loop: Header=BB4_5 Depth=1
	cbz	x28, .LBB4_94
// %bb.8:                               //   in Loop: Header=BB4_5 Depth=1
	mov	x25, x0
	cbz	x0, .LBB4_94
// %bb.9:                               //   in Loop: Header=BB4_5 Depth=1
	ldp	q16, q0, [sp, #96]              // 32-byte Folded Reload
	movi	v21.4s, #8
	mov	x8, #-14336                     // =0xffffffffffffc800
	ldp	q18, q7, [sp, #224]             // 32-byte Folded Reload
	ldp	q20, q19, [sp, #192]            // 32-byte Folded Reload
	ldr	q17, [sp, #80]                  // 16-byte Folded Reload
	.p2align	4, , 8
.LBB4_10:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mul	v1.4s, v0.4s, v7.4s
	add	x9, x26, x8
	adds	x8, x8, #32
	add	v0.4s, v0.4s, v21.4s
	add	v2.4s, v1.4s, v16.4s
	add	v1.4s, v1.4s, v17.4s
	umull2	v3.2d, v2.4s, v18.4s
	umull	v4.2d, v2.2s, v18.2s
	umull2	v5.2d, v1.4s, v18.4s
	umull	v6.2d, v1.2s, v18.2s
	uzp2	v3.4s, v4.4s, v3.4s
	uzp2	v4.4s, v6.4s, v5.4s
	ushr	v3.4s, v3.4s, #6
	ushr	v4.4s, v4.4s, #6
	mls	v2.4s, v3.4s, v19.4s
	mls	v1.4s, v4.4s, v19.4s
	ucvtf	v2.4s, v2.4s
	ucvtf	v1.4s, v1.4s
	fmul	v2.4s, v2.4s, v20.4s
	fmul	v1.4s, v1.4s, v20.4s
	str	q2, [x9, #14336]
	str	q1, [x9, #14352]
	b.ne	.LBB4_10
// %bb.11:                              //   in Loop: Header=BB4_5 Depth=1
	movi	v3.16b, #55
	add	x8, x28, #16
	movi	v4.16b, #53
	mov	x9, x20
	movi	v5.16b, #165
	ldr	q0, [sp, #176]                  // 16-byte Folded Reload
	movi	v6.16b, #32
	.p2align	4, , 8
.LBB4_12:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mul	v1.16b, v0.16b, v3.16b
	subs	x9, x9, #32
	add	v0.16b, v0.16b, v6.16b
	add	v2.16b, v1.16b, v4.16b
	add	v1.16b, v1.16b, v5.16b
	stp	q2, q1, [x8, #-16]
	add	x8, x8, #32
	b.ne	.LBB4_12
// %bb.13:                              //   in Loop: Header=BB4_5 Depth=1
	add	x8, x25, #16
	mov	x10, x19
	movi	v4.16b, #54
	mov	x9, x8
	movi	v5.16b, #166
	ldr	q0, [sp, #176]                  // 16-byte Folded Reload
	.p2align	4, , 8
.LBB4_14:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mul	v1.16b, v0.16b, v3.16b
	subs	x10, x10, #32
	add	v0.16b, v0.16b, v6.16b
	add	v2.16b, v1.16b, v4.16b
	add	v1.16b, v1.16b, v5.16b
	stp	q2, q1, [x9, #-16]
	add	x9, x9, #32
	b.ne	.LBB4_14
// %bb.15:                              //   in Loop: Header=BB4_5 Depth=1
	movi	v2.16b, #127
	cmp	w19, #1
	b.lt	.LBB4_18
// %bb.16:                              //   in Loop: Header=BB4_5 Depth=1
	ands	x9, x19, #0x7ffffc00
	b.eq	.LBB4_71
	.p2align	4, , 8
.LBB4_17:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldp	q0, q1, [x8, #-16]
	subs	x9, x9, #32
	and	v0.16b, v0.16b, v2.16b
	and	v1.16b, v1.16b, v2.16b
	stp	q0, q1, [x8, #-16]
	add	x8, x8, #32
	b.ne	.LBB4_17
.LBB4_18:                               //   in Loop: Header=BB4_5 Depth=1
	mov	x0, x24
	mov	x1, x26
	mov	x2, x28
	mov	x3, x25
	mov	w4, #3584                       // =0xe00
	mov	w5, w23
	mov	w6, #32                         // =0x20
	str	x21, [sp, #168]                 // 8-byte Folded Spill
	bl	pim_mxfp4_gemv
	mov	x0, x24
	mov	x1, x26
	mov	x2, x28
	mov	x3, x25
	mov	w4, #3584                       // =0xe00
	mov	w5, w23
	mov	w6, #32                         // =0x20
	bl	pim_mxfp4_gemv
	mov	x0, x24
	mov	x1, x26
	mov	x2, x28
	mov	x3, x25
	mov	w4, #3584                       // =0xe00
	mov	w5, w23
	mov	w6, #32                         // =0x20
	bl	pim_mxfp4_gemv
	mov	x0, x24
	mov	x1, x26
	mov	x2, x28
	mov	x3, x25
	mov	w4, #3584                       // =0xe00
	mov	w5, w23
	mov	w6, #32                         // =0x20
	bl	pim_mxfp4_gemv
	mov	x0, x24
	mov	x1, x26
	mov	x2, x28
	mov	x3, x25
	mov	w4, #3584                       // =0xe00
	mov	w5, w23
	mov	w6, #32                         // =0x20
	bl	pim_mxfp4_gemv
	add	x1, sp, #352
	mov	w0, #1                          // =0x1
	bl	clock_gettime
	ldr	q0, [sp, #352]
	mov	w21, w27
	cmp	w27, #1
	str	q0, [sp, #336]                  // 16-byte Folded Spill
	b.lt	.LBB4_20
	.p2align	4, , 8
.LBB4_19:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mov	x0, x24
	mov	x1, x26
	mov	x2, x28
	mov	x3, x25
	mov	w4, #3584                       // =0xe00
	mov	w5, w23
	mov	w6, #32                         // =0x20
	bl	pim_mxfp4_gemv
	subs	w21, w21, #1
	b.ne	.LBB4_19
.LBB4_20:                               //   in Loop: Header=BB4_5 Depth=1
	add	x1, sp, #352
	mov	w0, #1                          // =0x1
	bl	clock_gettime
	ldr	q0, [sp, #352]
	add	x8, x24, #8
	mov	x9, x23
	str	wzr, [sp, #352]
	.p2align	4, , 8
.LBB4_21:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldur	s1, [x8, #-8]
	subs	x9, x9, #4
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldur	s1, [x8, #-4]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x8]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x8, #4]
	add	x8, x8, #16
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	b.ne	.LBB4_21
// %bb.22:                              //   in Loop: Header=BB4_5 Depth=1
	ldr	q2, [sp, #336]                  // 16-byte Folded Reload
	mov	x8, #4655596114794250240        // =0x409c000000000000
	mov	x0, x26
	zip2	v1.2d, v0.2d, v2.2d
	zip1	v0.2d, v0.2d, v2.2d
	ldr	q2, [sp, #144]                  // 16-byte Folded Reload
	scvtf	v1.2d, v1.2d
	scvtf	v0.2d, v0.2d
	fmla	v0.2d, v2.2d, v1.2d
	fmov	d1, x8
	fmul	d8, d8, d1
	dup	v2.2d, v0.d[1]
	fsub	v0.2d, v0.2d, v2.2d
	str	q0, [sp, #336]                  // 16-byte Folded Spill
	ldr	s0, [sp, #352]
	bl	free
	mov	x0, x24
	bl	free
	mov	x0, x28
	bl	free
	mov	x0, x25
	bl	free
	ldr	d0, [sp, #72]                   // 8-byte Folded Reload
	mov	x8, #145685290680320            // =0x848000000000
	movk	x8, #16686, lsl #48
	adrp	x26, pim_mxfp4_gemv_opt
	add	x26, x26, :lo12:pim_mxfp4_gemv_opt
	mov	w1, w23
	fmul	d15, d8, d0
	ldr	q0, [sp, #336]                  // 16-byte Folded Reload
	fmov	d1, x8
	mov	x0, x26
	mov	w2, w27
	fdiv	d0, d15, d0
	fdiv	d8, d0, d1
	bl	bench_kernel
	adrp	x0, pim_mxfp4_gemv_opt_v2
	add	x0, x0, :lo12:pim_mxfp4_gemv_opt_v2
	mov	w1, w23
	mov	w2, w27
	fmov	d9, d0
	bl	bench_kernel
	adrp	x0, pim_mxfp4_gemv_opt_v3
	add	x0, x0, :lo12:pim_mxfp4_gemv_opt_v3
	mov	w1, w23
	mov	w2, w27
	fmov	d10, d0
	bl	bench_kernel
	adrp	x0, pim_mxfp4_gemv_opt_v4
	add	x0, x0, :lo12:pim_mxfp4_gemv_opt_v4
	mov	w1, w23
	mov	w2, w27
	fmov	d11, d0
	bl	bench_kernel
	fmul	d1, d8, d13
	fmov	d12, d0
	fmov	d0, d8
	adrp	x0, .L.str.6
	add	x0, x0, :lo12:.L.str.6
	bl	printf
	fdiv	d2, d9, d8
	fmul	d1, d9, d13
	fmov	d0, d9
	adrp	x0, .L.str.7
	add	x0, x0, :lo12:.L.str.7
	bl	printf
	fdiv	d2, d10, d8
	fmul	d1, d10, d13
	fmov	d0, d10
	adrp	x0, .L.str.8
	add	x0, x0, :lo12:.L.str.8
	bl	printf
	fdiv	d2, d11, d8
	fmul	d1, d11, d13
	fmov	d0, d11
	adrp	x0, .L.str.9
	add	x0, x0, :lo12:.L.str.9
	bl	printf
	fdiv	d2, d12, d8
	fmul	d1, d12, d13
	fmov	d0, d12
	adrp	x0, .L.str.10
	add	x0, x0, :lo12:.L.str.10
	bl	printf
	ldr	x21, [sp, #168]                 // 8-byte Folded Reload
	sub	w8, w21, #1
	cmp	w8, #1
	b.hi	.LBB4_4
// %bb.23:                              //   in Loop: Header=BB4_5 Depth=1
	mov	x0, x22
	bl	malloc
	mov	x21, x0
	mov	x0, x20
	bl	malloc
	mov	x24, x0
	mov	x0, x19
	bl	malloc
	cbz	x21, .LBB4_94
// %bb.24:                              //   in Loop: Header=BB4_5 Depth=1
	cbz	x24, .LBB4_94
// %bb.25:                              //   in Loop: Header=BB4_5 Depth=1
	cbz	x0, .LBB4_94
// %bb.26:                              //   in Loop: Header=BB4_5 Depth=1
	movi	v3.16b, #55
	add	x8, x24, #16
	movi	v4.16b, #32
	ldr	q0, [sp, #176]                  // 16-byte Folded Reload
	movi	v5.16b, #121
	movi	v6.16b, #233
	.p2align	4, , 8
.LBB4_27:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mul	v1.16b, v0.16b, v3.16b
	subs	x20, x20, #32
	add	v0.16b, v0.16b, v4.16b
	add	v2.16b, v1.16b, v5.16b
	add	v1.16b, v1.16b, v6.16b
	stp	q2, q1, [x8, #-16]
	add	x8, x8, #32
	b.ne	.LBB4_27
// %bb.28:                              //   in Loop: Header=BB4_5 Depth=1
	add	x8, x0, #16
	adrp	x9, .LCPI4_1
	ldr	q0, [x9, :lo12:.LCPI4_1]
	mov	x9, x8
	movi	v5.16b, #122
	mov	x10, x19
	movi	v6.16b, #234
	.p2align	4, , 8
.LBB4_29:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mul	v1.16b, v0.16b, v3.16b
	subs	x10, x10, #32
	add	v0.16b, v0.16b, v4.16b
	add	v2.16b, v1.16b, v5.16b
	add	v1.16b, v1.16b, v6.16b
	stp	q2, q1, [x9, #-16]
	add	x9, x9, #32
	b.ne	.LBB4_29
// %bb.30:                              //   in Loop: Header=BB4_5 Depth=1
	movi	v2.16b, #127
	cmp	w19, #1
	b.lt	.LBB4_33
// %bb.31:                              //   in Loop: Header=BB4_5 Depth=1
	ands	x9, x19, #0x7ffffc00
	b.eq	.LBB4_72
	.p2align	4, , 8
.LBB4_32:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldp	q0, q1, [x8, #-16]
	subs	x9, x9, #32
	and	v0.16b, v0.16b, v2.16b
	and	v1.16b, v1.16b, v2.16b
	stp	q0, q1, [x8, #-16]
	add	x8, x8, #32
	b.ne	.LBB4_32
.LBB4_33:                               //   in Loop: Header=BB4_5 Depth=1
	str	x0, [sp, #304]                  // 8-byte Folded Spill
	mov	w0, #64                         // =0x40
	bl	malloc
	mov	x27, x0
	mov	w0, #14336                      // =0x3800
	bl	malloc
	ldp	q16, q7, [sp, #224]             // 32-byte Folded Reload
	movi	v19.4s, #8
	mov	w10, #22236                     // =0x56dc
	mov	w11, #15776                     // =0x3da0
	adrp	x19, .LCPI4_0
	add	x8, x0, #16
	mov	w9, #3584                       // =0xe00
	movk	w10, #57005, lsl #16
	movk	w11, #22411, lsl #16
	str	x0, [x27]
	ldp	q18, q17, [sp, #192]            // 32-byte Folded Reload
	ldr	q0, [x19, :lo12:.LCPI4_0]
	.p2align	4, , 8
.LBB4_34:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mul	v1.4s, v0.4s, v7.4s
	subs	x9, x9, #8
	dup	v2.4s, w10
	dup	v3.4s, w11
	add	v0.4s, v0.4s, v19.4s
	add	v2.4s, v1.4s, v2.4s
	add	v1.4s, v1.4s, v3.4s
	umull2	v3.2d, v2.4s, v16.4s
	umull	v4.2d, v2.2s, v16.2s
	umull2	v5.2d, v1.4s, v16.4s
	umull	v6.2d, v1.2s, v16.2s
	uzp2	v3.4s, v4.4s, v3.4s
	uzp2	v4.4s, v6.4s, v5.4s
	ushr	v3.4s, v3.4s, #6
	ushr	v4.4s, v4.4s, #6
	mls	v2.4s, v3.4s, v17.4s
	mls	v1.4s, v4.4s, v17.4s
	ucvtf	v2.4s, v2.4s
	ucvtf	v1.4s, v1.4s
	fmul	v2.4s, v2.4s, v18.4s
	fmul	v1.4s, v1.4s, v18.4s
	stp	q2, q1, [x8, #-16]
	add	x8, x8, #32
	b.ne	.LBB4_34
// %bb.35:                              //   in Loop: Header=BB4_5 Depth=1
	mov	w0, #14336                      // =0x3800
	bl	malloc
	ldp	q18, q17, [sp, #192]            // 32-byte Folded Reload
	movi	v19.4s, #8
	mov	w10, #22237                     // =0x56dd
	mov	w11, #15777                     // =0x3da1
	mov	x8, #-14336                     // =0xffffffffffffc800
	movk	w10, #57005, lsl #16
	movk	w11, #22411, lsl #16
	str	x0, [x27, #8]
	ldp	q16, q7, [sp, #224]             // 32-byte Folded Reload
	ldr	q0, [x19, :lo12:.LCPI4_0]
	.p2align	4, , 8
.LBB4_36:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mul	v1.4s, v0.4s, v7.4s
	add	x9, x0, x8
	dup	v2.4s, w10
	adds	x8, x8, #32
	dup	v3.4s, w11
	add	v0.4s, v0.4s, v19.4s
	add	v2.4s, v1.4s, v2.4s
	add	v1.4s, v1.4s, v3.4s
	umull2	v3.2d, v2.4s, v16.4s
	umull	v4.2d, v2.2s, v16.2s
	umull2	v5.2d, v1.4s, v16.4s
	umull	v6.2d, v1.2s, v16.2s
	uzp2	v3.4s, v4.4s, v3.4s
	uzp2	v4.4s, v6.4s, v5.4s
	ushr	v3.4s, v3.4s, #6
	ushr	v4.4s, v4.4s, #6
	mls	v2.4s, v3.4s, v17.4s
	mls	v1.4s, v4.4s, v17.4s
	ucvtf	v2.4s, v2.4s
	ucvtf	v1.4s, v1.4s
	fmul	v2.4s, v2.4s, v18.4s
	fmul	v1.4s, v1.4s, v18.4s
	str	q2, [x9, #14336]
	str	q1, [x9, #14352]
	b.ne	.LBB4_36
// %bb.37:                              //   in Loop: Header=BB4_5 Depth=1
	str	x0, [sp, #64]                   // 8-byte Folded Spill
	mov	w0, #14336                      // =0x3800
	bl	malloc
	ldp	q18, q17, [sp, #192]            // 32-byte Folded Reload
	movi	v19.4s, #8
	mov	w10, #22238                     // =0x56de
	mov	w11, #15778                     // =0x3da2
	mov	x8, #-14336                     // =0xffffffffffffc800
	movk	w10, #57005, lsl #16
	movk	w11, #22411, lsl #16
	str	x0, [x27, #16]
	ldp	q16, q7, [sp, #224]             // 32-byte Folded Reload
	ldr	q0, [x19, :lo12:.LCPI4_0]
	.p2align	4, , 8
.LBB4_38:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mul	v1.4s, v0.4s, v7.4s
	add	x9, x0, x8
	dup	v2.4s, w10
	adds	x8, x8, #32
	dup	v3.4s, w11
	add	v0.4s, v0.4s, v19.4s
	add	v2.4s, v1.4s, v2.4s
	add	v1.4s, v1.4s, v3.4s
	umull2	v3.2d, v2.4s, v16.4s
	umull	v4.2d, v2.2s, v16.2s
	umull2	v5.2d, v1.4s, v16.4s
	umull	v6.2d, v1.2s, v16.2s
	uzp2	v3.4s, v4.4s, v3.4s
	uzp2	v4.4s, v6.4s, v5.4s
	ushr	v3.4s, v3.4s, #6
	ushr	v4.4s, v4.4s, #6
	mls	v2.4s, v3.4s, v17.4s
	mls	v1.4s, v4.4s, v17.4s
	ucvtf	v2.4s, v2.4s
	ucvtf	v1.4s, v1.4s
	fmul	v2.4s, v2.4s, v18.4s
	fmul	v1.4s, v1.4s, v18.4s
	str	q2, [x9, #14336]
	str	q1, [x9, #14352]
	b.ne	.LBB4_38
// %bb.39:                              //   in Loop: Header=BB4_5 Depth=1
	str	x0, [sp, #56]                   // 8-byte Folded Spill
	mov	w0, #14336                      // =0x3800
	bl	malloc
	ldp	q18, q17, [sp, #192]            // 32-byte Folded Reload
	movi	v19.4s, #8
	mov	w10, #22239                     // =0x56df
	mov	w11, #15779                     // =0x3da3
	mov	x8, #-14336                     // =0xffffffffffffc800
	movk	w10, #57005, lsl #16
	movk	w11, #22411, lsl #16
	str	x0, [x27, #24]
	ldp	q16, q7, [sp, #224]             // 32-byte Folded Reload
	ldr	q0, [x19, :lo12:.LCPI4_0]
	.p2align	4, , 8
.LBB4_40:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mul	v1.4s, v0.4s, v7.4s
	add	x9, x0, x8
	dup	v2.4s, w10
	adds	x8, x8, #32
	dup	v3.4s, w11
	add	v0.4s, v0.4s, v19.4s
	add	v2.4s, v1.4s, v2.4s
	add	v1.4s, v1.4s, v3.4s
	umull2	v3.2d, v2.4s, v16.4s
	umull	v4.2d, v2.2s, v16.2s
	umull2	v5.2d, v1.4s, v16.4s
	umull	v6.2d, v1.2s, v16.2s
	uzp2	v3.4s, v4.4s, v3.4s
	uzp2	v4.4s, v6.4s, v5.4s
	ushr	v3.4s, v3.4s, #6
	ushr	v4.4s, v4.4s, #6
	mls	v2.4s, v3.4s, v17.4s
	mls	v1.4s, v4.4s, v17.4s
	ucvtf	v2.4s, v2.4s
	ucvtf	v1.4s, v1.4s
	fmul	v2.4s, v2.4s, v18.4s
	fmul	v1.4s, v1.4s, v18.4s
	str	q2, [x9, #14336]
	str	q1, [x9, #14352]
	b.ne	.LBB4_40
// %bb.41:                              //   in Loop: Header=BB4_5 Depth=1
	str	x0, [sp, #48]                   // 8-byte Folded Spill
	mov	w0, #14336                      // =0x3800
	bl	malloc
	ldp	q18, q17, [sp, #192]            // 32-byte Folded Reload
	movi	v19.4s, #8
	mov	w10, #22240                     // =0x56e0
	mov	w11, #15780                     // =0x3da4
	mov	x8, #-14336                     // =0xffffffffffffc800
	movk	w10, #57005, lsl #16
	movk	w11, #22411, lsl #16
	str	x0, [x27, #32]
	ldp	q16, q7, [sp, #224]             // 32-byte Folded Reload
	ldr	q0, [x19, :lo12:.LCPI4_0]
	.p2align	4, , 8
.LBB4_42:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mul	v1.4s, v0.4s, v7.4s
	add	x9, x0, x8
	dup	v2.4s, w10
	adds	x8, x8, #32
	dup	v3.4s, w11
	add	v0.4s, v0.4s, v19.4s
	add	v2.4s, v1.4s, v2.4s
	add	v1.4s, v1.4s, v3.4s
	umull2	v3.2d, v2.4s, v16.4s
	umull	v4.2d, v2.2s, v16.2s
	umull2	v5.2d, v1.4s, v16.4s
	umull	v6.2d, v1.2s, v16.2s
	uzp2	v3.4s, v4.4s, v3.4s
	uzp2	v4.4s, v6.4s, v5.4s
	ushr	v3.4s, v3.4s, #6
	ushr	v4.4s, v4.4s, #6
	mls	v2.4s, v3.4s, v17.4s
	mls	v1.4s, v4.4s, v17.4s
	ucvtf	v2.4s, v2.4s
	ucvtf	v1.4s, v1.4s
	fmul	v2.4s, v2.4s, v18.4s
	fmul	v1.4s, v1.4s, v18.4s
	str	q2, [x9, #14336]
	str	q1, [x9, #14352]
	b.ne	.LBB4_42
// %bb.43:                              //   in Loop: Header=BB4_5 Depth=1
	str	x0, [sp, #40]                   // 8-byte Folded Spill
	mov	w0, #14336                      // =0x3800
	bl	malloc
	ldp	q18, q17, [sp, #192]            // 32-byte Folded Reload
	movi	v19.4s, #8
	mov	w10, #22241                     // =0x56e1
	mov	w11, #15781                     // =0x3da5
	mov	x8, #-14336                     // =0xffffffffffffc800
	movk	w10, #57005, lsl #16
	movk	w11, #22411, lsl #16
	str	x0, [x27, #40]
	ldp	q16, q7, [sp, #224]             // 32-byte Folded Reload
	ldr	q0, [x19, :lo12:.LCPI4_0]
	.p2align	4, , 8
.LBB4_44:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mul	v1.4s, v0.4s, v7.4s
	add	x9, x0, x8
	dup	v2.4s, w10
	adds	x8, x8, #32
	dup	v3.4s, w11
	add	v0.4s, v0.4s, v19.4s
	add	v2.4s, v1.4s, v2.4s
	add	v1.4s, v1.4s, v3.4s
	umull2	v3.2d, v2.4s, v16.4s
	umull	v4.2d, v2.2s, v16.2s
	umull2	v5.2d, v1.4s, v16.4s
	umull	v6.2d, v1.2s, v16.2s
	uzp2	v3.4s, v4.4s, v3.4s
	uzp2	v4.4s, v6.4s, v5.4s
	ushr	v3.4s, v3.4s, #6
	ushr	v4.4s, v4.4s, #6
	mls	v2.4s, v3.4s, v17.4s
	mls	v1.4s, v4.4s, v17.4s
	ucvtf	v2.4s, v2.4s
	ucvtf	v1.4s, v1.4s
	fmul	v2.4s, v2.4s, v18.4s
	fmul	v1.4s, v1.4s, v18.4s
	str	q2, [x9, #14336]
	str	q1, [x9, #14352]
	b.ne	.LBB4_44
// %bb.45:                              //   in Loop: Header=BB4_5 Depth=1
	str	x0, [sp, #32]                   // 8-byte Folded Spill
	mov	w0, #14336                      // =0x3800
	bl	malloc
	ldp	q18, q17, [sp, #192]            // 32-byte Folded Reload
	movi	v19.4s, #8
	mov	w10, #22242                     // =0x56e2
	mov	w11, #15782                     // =0x3da6
	mov	x8, #-14336                     // =0xffffffffffffc800
	movk	w10, #57005, lsl #16
	movk	w11, #22411, lsl #16
	str	x0, [x27, #48]
	ldp	q16, q7, [sp, #224]             // 32-byte Folded Reload
	ldr	q0, [x19, :lo12:.LCPI4_0]
	.p2align	4, , 8
.LBB4_46:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mul	v1.4s, v0.4s, v7.4s
	add	x9, x0, x8
	dup	v2.4s, w10
	adds	x8, x8, #32
	dup	v3.4s, w11
	add	v0.4s, v0.4s, v19.4s
	add	v2.4s, v1.4s, v2.4s
	add	v1.4s, v1.4s, v3.4s
	umull2	v3.2d, v2.4s, v16.4s
	umull	v4.2d, v2.2s, v16.2s
	umull2	v5.2d, v1.4s, v16.4s
	umull	v6.2d, v1.2s, v16.2s
	uzp2	v3.4s, v4.4s, v3.4s
	uzp2	v4.4s, v6.4s, v5.4s
	ushr	v3.4s, v3.4s, #6
	ushr	v4.4s, v4.4s, #6
	mls	v2.4s, v3.4s, v17.4s
	mls	v1.4s, v4.4s, v17.4s
	ucvtf	v2.4s, v2.4s
	ucvtf	v1.4s, v1.4s
	fmul	v2.4s, v2.4s, v18.4s
	fmul	v1.4s, v1.4s, v18.4s
	str	q2, [x9, #14336]
	str	q1, [x9, #14352]
	b.ne	.LBB4_46
// %bb.47:                              //   in Loop: Header=BB4_5 Depth=1
	str	x0, [sp, #24]                   // 8-byte Folded Spill
	mov	w0, #14336                      // =0x3800
	stp	x24, x21, [sp, #288]            // 16-byte Folded Spill
	bl	malloc
	ldp	q18, q17, [sp, #192]            // 32-byte Folded Reload
	movi	v19.4s, #8
	mov	w10, #22243                     // =0x56e3
	mov	w11, #15783                     // =0x3da7
	mov	x8, #-14336                     // =0xffffffffffffc800
	movk	w10, #57005, lsl #16
	movk	w11, #22411, lsl #16
	str	x0, [x27, #56]
	ldp	q16, q7, [sp, #224]             // 32-byte Folded Reload
	ldr	q0, [x19, :lo12:.LCPI4_0]
	.p2align	4, , 8
.LBB4_48:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	mul	v1.4s, v0.4s, v7.4s
	add	x9, x0, x8
	dup	v2.4s, w10
	adds	x8, x8, #32
	dup	v3.4s, w11
	add	v0.4s, v0.4s, v19.4s
	add	v2.4s, v1.4s, v2.4s
	add	v1.4s, v1.4s, v3.4s
	umull2	v3.2d, v2.4s, v16.4s
	umull	v4.2d, v2.2s, v16.2s
	umull2	v5.2d, v1.4s, v16.4s
	umull	v6.2d, v1.2s, v16.2s
	uzp2	v3.4s, v4.4s, v3.4s
	uzp2	v4.4s, v6.4s, v5.4s
	ushr	v3.4s, v3.4s, #6
	ushr	v4.4s, v4.4s, #6
	mls	v2.4s, v3.4s, v17.4s
	mls	v1.4s, v4.4s, v17.4s
	ucvtf	v2.4s, v2.4s
	ucvtf	v1.4s, v1.4s
	fmul	v2.4s, v2.4s, v18.4s
	fmul	v1.4s, v1.4s, v18.4s
	str	q2, [x9, #14336]
	str	q1, [x9, #14352]
	b.ne	.LBB4_48
// %bb.49:                              //   in Loop: Header=BB4_5 Depth=1
	cmp	w23, #8
	mov	w9, #8                          // =0x8
	csel	w22, w23, w9, lt
	mov	x20, xzr
	add	w9, w23, w22
	add	x19, sp, #352
	sub	w9, w9, #1
	adrp	x24, mt_worker
	add	x24, x24, :lo12:mt_worker
	ldr	x25, [sp, #288]                 // 8-byte Folded Reload
	sdiv	w9, w9, w22
	str	x0, [sp, #16]                   // 8-byte Folded Spill
	ldp	x21, x28, [sp, #296]            // 16-byte Folded Reload
	str	x22, [sp, #272]                 // 8-byte Folded Spill
	str	x27, [sp, #336]                 // 8-byte Folded Spill
	str	w9, [sp, #320]                  // 4-byte Folded Spill
	.p2align	4, , 8
.LBB4_50:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldr	w10, [sp, #320]                 // 4-byte Folded Reload
	mov	x1, xzr
	ldr	x9, [x27, x20]
	mov	x2, x24
	mov	x3, x19
	stp	x26, x21, [x19]
	add	w27, w10, w8
	adrp	x10, .LCPI4_3
	ldr	d9, [x10, :lo12:.LCPI4_3]
	cmp	w27, w23
	str	x9, [x19, #16]
	csel	w9, w27, w23, lt
	stp	x25, x28, [x19, #24]
	str	d9, [x19, #40]
	stp	w8, w9, [x19, #48]
	sub	x8, x29, #200
	add	x0, x8, x20
	bl	pthread_create
	add	x20, x20, #8
	add	x19, x19, #56
	mov	w8, w27
	ldr	x27, [sp, #336]                 // 8-byte Folded Reload
	subs	x22, x22, #1
	b.ne	.LBB4_50
// %bb.51:                              //   in Loop: Header=BB4_5 Depth=1
	mov	x19, xzr
	sub	x20, x29, #200
	ldr	x22, [sp, #272]                 // 8-byte Folded Reload
	str	x23, [sp, #280]                 // 8-byte Folded Spill
	.p2align	4, , 8
.LBB4_52:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldr	x0, [x20, x19, lsl #3]
	mov	x1, xzr
	bl	pthread_join
	add	x19, x19, #1
	cmp	x22, x19
	b.ne	.LBB4_52
// %bb.53:                              //   in Loop: Header=BB4_5 Depth=1
	ldp	x21, x23, [sp, #296]            // 16-byte Folded Reload
	mov	w8, wzr
	mov	x20, xzr
	ldp	x28, x25, [sp, #280]            // 16-byte Folded Reload
	add	x19, sp, #352
	ldr	w24, [sp, #320]                 // 4-byte Folded Reload
	.p2align	4, , 8
.LBB4_54:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldr	x9, [x27, x20]
	add	w27, w24, w8
	cmp	w27, w28
	mov	x1, xzr
	adrp	x2, mt_worker
	add	x2, x2, :lo12:mt_worker
	mov	x3, x19
	stp	x26, x21, [x19]
	str	x9, [x19, #16]
	csel	w9, w27, w28, lt
	stp	x25, x23, [x19, #24]
	str	d9, [x19, #40]
	stp	w8, w9, [x19, #48]
	sub	x8, x29, #200
	add	x0, x8, x20
	bl	pthread_create
	add	x20, x20, #8
	add	x19, x19, #56
	mov	w8, w27
	ldr	x27, [sp, #336]                 // 8-byte Folded Reload
	subs	x22, x22, #1
	b.ne	.LBB4_54
// %bb.55:                              //   in Loop: Header=BB4_5 Depth=1
	mov	x19, xzr
	ldr	x22, [sp, #272]                 // 8-byte Folded Reload
	sub	x20, x29, #200
	.p2align	4, , 8
.LBB4_56:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldr	x0, [x20, x19, lsl #3]
	mov	x1, xzr
	bl	pthread_join
	add	x19, x19, #1
	cmp	x22, x19
	b.ne	.LBB4_56
// %bb.57:                              //   in Loop: Header=BB4_5 Depth=1
	ldp	x21, x23, [sp, #296]            // 16-byte Folded Reload
	mov	w8, wzr
	mov	x20, xzr
	ldp	x28, x25, [sp, #280]            // 16-byte Folded Reload
	add	x19, sp, #352
	ldr	w24, [sp, #320]                 // 4-byte Folded Reload
	.p2align	4, , 8
.LBB4_58:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldr	x9, [x27, x20]
	add	w27, w24, w8
	cmp	w27, w28
	mov	x1, xzr
	adrp	x2, mt_worker
	add	x2, x2, :lo12:mt_worker
	mov	x3, x19
	stp	x26, x21, [x19]
	str	x9, [x19, #16]
	csel	w9, w27, w28, lt
	stp	x25, x23, [x19, #24]
	str	d9, [x19, #40]
	stp	w8, w9, [x19, #48]
	sub	x8, x29, #200
	add	x0, x8, x20
	bl	pthread_create
	add	x20, x20, #8
	add	x19, x19, #56
	mov	w8, w27
	ldr	x27, [sp, #336]                 // 8-byte Folded Reload
	subs	x22, x22, #1
	b.ne	.LBB4_58
// %bb.59:                              //   in Loop: Header=BB4_5 Depth=1
	mov	x19, xzr
	ldr	x28, [sp, #272]                 // 8-byte Folded Reload
	sub	x20, x29, #200
	.p2align	4, , 8
.LBB4_60:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldr	x0, [x20, x19, lsl #3]
	mov	x1, xzr
	bl	pthread_join
	add	x19, x19, #1
	cmp	x28, x19
	b.ne	.LBB4_60
// %bb.61:                              //   in Loop: Header=BB4_5 Depth=1
	add	x1, sp, #352
	mov	w0, #1                          // =0x1
	bl	clock_gettime
	ldr	w27, [sp, #268]                 // 4-byte Folded Reload
	ldr	q0, [sp, #352]
	cmp	w27, #1
	str	q0, [sp]                        // 16-byte Folded Spill
	b.lt	.LBB4_68
// %bb.62:                              //   in Loop: Header=BB4_5 Depth=1
	mov	w8, wzr
	.p2align	4, , 8
.LBB4_63:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Loop Header: Depth=2
                                        //       Child Loop BB4_64 Depth 3
                                        //       Child Loop BB4_66 Depth 3
	ldp	x21, x23, [sp, #296]            // 16-byte Folded Reload
	str	w8, [sp, #316]                  // 4-byte Folded Spill
	mov	w8, wzr
	ldp	x22, x25, [sp, #280]            // 16-byte Folded Reload
	sub	x20, x29, #200
	add	x19, sp, #352
	ldr	x27, [sp, #336]                 // 8-byte Folded Reload
	ldr	w24, [sp, #320]                 // 4-byte Folded Reload
	.p2align	4, , 8
.LBB4_64:                               //   Parent Loop BB4_5 Depth=1
                                        //     Parent Loop BB4_63 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldr	x9, [x27], #8
	stp	x26, x21, [x19]
	add	w26, w24, w8
	cmp	w26, w22
	mov	x0, x20
	stp	x9, x25, [x19, #16]
	csel	w9, w26, w22, lt
	mov	x1, xzr
	adrp	x2, mt_worker
	add	x2, x2, :lo12:mt_worker
	mov	x3, x19
	str	x23, [x19, #32]
	str	d9, [x19, #40]
	stp	w8, w9, [x19, #48]
	bl	pthread_create
	add	x20, x20, #8
	add	x19, x19, #56
	mov	w8, w26
	adrp	x26, pim_mxfp4_gemv_opt
	add	x26, x26, :lo12:pim_mxfp4_gemv_opt
	subs	x28, x28, #1
	b.ne	.LBB4_64
// %bb.65:                              //   in Loop: Header=BB4_63 Depth=2
	mov	x19, xzr
	sub	x20, x29, #200
	ldr	x28, [sp, #272]                 // 8-byte Folded Reload
	.p2align	4, , 8
.LBB4_66:                               //   Parent Loop BB4_5 Depth=1
                                        //     Parent Loop BB4_63 Depth=2
                                        // =>    This Inner Loop Header: Depth=3
	ldr	x0, [x20, x19, lsl #3]
	mov	x1, xzr
	bl	pthread_join
	add	x19, x19, #1
	cmp	x28, x19
	b.ne	.LBB4_66
// %bb.67:                              //   in Loop: Header=BB4_63 Depth=2
	ldr	w8, [sp, #316]                  // 4-byte Folded Reload
	ldr	w27, [sp, #268]                 // 4-byte Folded Reload
	add	w8, w8, #1
	cmp	w8, w27
	b.ne	.LBB4_63
.LBB4_68:                               //   in Loop: Header=BB4_5 Depth=1
	add	x1, sp, #352
	mov	w0, #1                          // =0x1
	bl	clock_gettime
	ldr	q0, [sp, #352]
	ldr	x19, [sp, #296]                 // 8-byte Folded Reload
	str	q0, [sp, #320]                  // 16-byte Folded Spill
	str	wzr, [sp, #352]
	add	x8, x19, #8
	ldr	x9, [sp, #280]                  // 8-byte Folded Reload
	.p2align	4, , 8
.LBB4_69:                               //   Parent Loop BB4_5 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	ldur	s0, [x8, #-8]
	subs	x9, x9, #4
	ldr	s1, [sp, #352]
	fadd	s0, s0, s1
	str	s0, [sp, #352]
	ldur	s0, [x8, #-4]
	ldr	s1, [sp, #352]
	fadd	s0, s0, s1
	str	s0, [sp, #352]
	ldr	s0, [x8]
	ldr	s1, [sp, #352]
	fadd	s0, s0, s1
	str	s0, [sp, #352]
	ldr	s0, [x8, #4]
	add	x8, x8, #16
	ldr	s1, [sp, #352]
	fadd	s0, s0, s1
	str	s0, [sp, #352]
	b.ne	.LBB4_69
// %bb.70:                              //   in Loop: Header=BB4_5 Depth=1
	ldr	s0, [sp, #352]
	ldr	x20, [sp, #336]                 // 8-byte Folded Reload
	ldr	x0, [x20]
	bl	free
	ldr	x0, [sp, #64]                   // 8-byte Folded Reload
	bl	free
	ldr	x0, [sp, #56]                   // 8-byte Folded Reload
	bl	free
	ldr	x0, [sp, #48]                   // 8-byte Folded Reload
	bl	free
	ldr	x0, [sp, #40]                   // 8-byte Folded Reload
	bl	free
	ldr	x0, [sp, #32]                   // 8-byte Folded Reload
	bl	free
	ldr	x0, [sp, #24]                   // 8-byte Folded Reload
	bl	free
	ldr	x0, [sp, #16]                   // 8-byte Folded Reload
	bl	free
	ldr	q1, [sp]                        // 16-byte Folded Reload
	mov	x0, x20
	ldr	q2, [sp, #320]                  // 16-byte Folded Reload
	zip2	v0.2d, v2.2d, v1.2d
	zip1	v1.2d, v2.2d, v1.2d
	ldr	q2, [sp, #144]                  // 16-byte Folded Reload
	scvtf	v0.2d, v0.2d
	scvtf	v1.2d, v1.2d
	fmla	v1.2d, v2.2d, v0.2d
	dup	v0.2d, v1.d[1]
	fsub	v0.2d, v1.2d, v0.2d
	str	q0, [sp, #320]                  // 16-byte Folded Spill
	bl	free
	mov	x0, x19
	bl	free
	ldr	x0, [sp, #288]                  // 8-byte Folded Reload
	bl	free
	ldr	x0, [sp, #304]                  // 8-byte Folded Reload
	bl	free
	ldr	q0, [sp, #320]                  // 16-byte Folded Reload
	mov	x8, #145685290680320            // =0x848000000000
	movk	x8, #16686, lsl #48
	adrp	x0, .L.str.11
	add	x0, x0, :lo12:.L.str.11
	fdiv	d0, d15, d0
	fmov	d1, x8
	fdiv	d0, d0, d1
	fdiv	d2, d0, d8
	fmul	d1, d0, d13
	bl	printf
	ldr	x21, [sp, #168]                 // 8-byte Folded Reload
	b	.LBB4_4
	.p2align	4, , 8
.LBB4_71:                               // =>This Inner Loop Header: Depth=1
	ldrb	w8, [x25]
	and	w8, w8, #0x7f
	strb	w8, [x25], #1
	b	.LBB4_71
	.p2align	4, , 8
.LBB4_72:                               // =>This Inner Loop Header: Depth=1
	ldrb	w8, [x0]
	and	w8, w8, #0x7f
	strb	w8, [x0], #1
	b	.LBB4_72
.LBB4_73:
	adrp	x0, .Lstr.25
	add	x0, x0, :lo12:.Lstr.25
	adrp	x23, .LCPI4_0
	bl	puts
	mov	w0, #36700160                   // =0x2300000
	bl	malloc
	mov	x19, x0
	mov	w0, #14336                      // =0x3800
	bl	malloc
	mov	x20, x0
	mov	w0, #16384                      // =0x4000
	movk	w0, #1, lsl #16
	bl	malloc
	mov	x21, x0
	mov	w0, #2293760                    // =0x230000
	bl	malloc
	cbz	x19, .LBB4_94
// %bb.74:
	cbz	x20, .LBB4_94
// %bb.75:
	cbz	x21, .LBB4_94
// %bb.76:
	mov	x22, x0
	cbz	x0, .LBB4_94
// %bb.77:
	adrp	x8, .LCPI4_1
	ldr	q0, [x8, :lo12:.LCPI4_1]
	movi	v1.16b, #55
	add	x8, x19, #16
	movi	v2.16b, #154
	mov	w9, #36700160                   // =0x2300000
	movi	v3.16b, #10
	movi	v4.16b, #32
	.p2align	4, , 8
.LBB4_78:                               // =>This Inner Loop Header: Depth=1
	mul	v5.16b, v0.16b, v1.16b
	subs	x9, x9, #32
	add	v0.16b, v0.16b, v4.16b
	add	v6.16b, v5.16b, v2.16b
	add	v5.16b, v5.16b, v3.16b
	stp	q6, q5, [x8, #-16]
	add	x8, x8, #32
	b.ne	.LBB4_78
// %bb.79:
	mov	w8, #31153                      // =0x79b1
	mov	w10, #32861                     // =0x805d
	movk	w8, #40503, lsl #16
	mov	w9, #39321                      // =0x9999
	movk	w10, #14285, lsl #16
	movk	w9, #48879, lsl #16
	movi	v4.4s, #8
	ldr	q0, [x23, :lo12:.LCPI4_0]
	dup	v1.4s, w8
	mov	w8, #19923                      // =0x4dd3
	movk	w8, #4194, lsl #16
	dup	v3.4s, w10
	mov	w10, #55050                     // =0xd70a
	dup	v2.4s, w9
	mov	w9, #1000                       // =0x3e8
	movk	w10, #15395, lsl #16
	dup	v5.4s, w8
	mov	x8, #-14336                     // =0xffffffffffffc800
	dup	v6.4s, w9
	dup	v7.4s, w10
	.p2align	4, , 8
.LBB4_80:                               // =>This Inner Loop Header: Depth=1
	mul	v16.4s, v0.4s, v1.4s
	add	x9, x20, x8
	adds	x8, x8, #32
	add	v0.4s, v0.4s, v4.4s
	add	v17.4s, v16.4s, v2.4s
	add	v16.4s, v16.4s, v3.4s
	umull2	v18.2d, v17.4s, v5.4s
	umull	v19.2d, v17.2s, v5.2s
	umull2	v20.2d, v16.4s, v5.4s
	umull	v21.2d, v16.2s, v5.2s
	uzp2	v18.4s, v19.4s, v18.4s
	uzp2	v19.4s, v21.4s, v20.4s
	ushr	v18.4s, v18.4s, #6
	ushr	v19.4s, v19.4s, #6
	mls	v17.4s, v18.4s, v6.4s
	mls	v16.4s, v19.4s, v6.4s
	ucvtf	v17.4s, v17.4s
	ucvtf	v16.4s, v16.4s
	fmul	v17.4s, v17.4s, v7.4s
	fmul	v16.4s, v16.4s, v7.4s
	str	q17, [x9, #14336]
	str	q16, [x9, #14352]
	b.ne	.LBB4_80
// %bb.81:
	movi	v0.16b, #55
	adrp	x9, .LCPI4_1
	ldr	q4, [x9, :lo12:.LCPI4_1]
	movi	v1.16b, #155
	movi	v2.16b, #11
	movi	v3.16b, #32
	.p2align	4, , 8
.LBB4_82:                               // =>This Inner Loop Header: Depth=1
	mul	v5.16b, v4.16b, v0.16b
	add	x9, x22, x8
	add	x8, x8, #32
	add	v4.16b, v4.16b, v3.16b
	cmp	x8, #560, lsl #12               // =2293760
	add	v6.16b, v5.16b, v1.16b
	add	v5.16b, v5.16b, v2.16b
	stp	q6, q5, [x9]
	b.ne	.LBB4_82
// %bb.83:
	movi	v0.16b, #127
	mov	x8, xzr
	.p2align	4, , 8
.LBB4_84:                               // =>This Inner Loop Header: Depth=1
	add	x9, x22, x8
	add	x8, x8, #32
	cmp	x8, #560, lsl #12               // =2293760
	ldp	q1, q2, [x9]
	and	v1.16b, v1.16b, v0.16b
	and	v2.16b, v2.16b, v0.16b
	stp	q1, q2, [x9]
	b.ne	.LBB4_84
// %bb.85:
	mov	w0, #8388608                    // =0x800000
	bl	malloc
	cbz	x0, .LBB4_95
// %bb.86:
	mov	x23, x0
	mov	x0, x21
	mov	x1, x20
	mov	x2, x19
	mov	x3, x22
	mov	w4, #3584                       // =0xe00
	mov	w5, #20480                      // =0x5000
	mov	w6, #32                         // =0x20
	bl	pim_mxfp4_gemv
	mov	x0, x21
	mov	x1, x20
	mov	x2, x19
	mov	x3, x22
	mov	w4, #3584                       // =0xe00
	mov	w5, #20480                      // =0x5000
	mov	w6, #32                         // =0x20
	bl	pim_mxfp4_gemv
	mov	x0, x21
	mov	x1, x20
	mov	x2, x19
	mov	x3, x22
	mov	w4, #3584                       // =0xe00
	mov	w5, #20480                      // =0x5000
	mov	w6, #32                         // =0x20
	bl	pim_mxfp4_gemv
	add	x1, sp, #352
	mov	w0, #1                          // =0x1
	bl	clock_gettime
	ldr	q0, [sp, #352]
	cmp	w27, #1
	str	q0, [sp, #336]                  // 16-byte Folded Spill
	b.lt	.LBB4_91
// %bb.87:
	mov	w25, wzr
	mov	w26, #64                        // =0x40
	mov	w27, #128                       // =0x80
	mov	w28, #192                       // =0xc0
	mov	w24, #8388544                   // =0x7fffc0
	.p2align	4, , 8
.LBB4_88:                               // =>This Loop Header: Depth=1
                                        //     Child Loop BB4_89 Depth 2
	mov	x0, x21
	mov	x1, x20
	mov	x2, x19
	mov	x3, x22
	mov	w4, #3584                       // =0xe00
	mov	w5, #20480                      // =0x5000
	mov	w6, #32                         // =0x20
	bl	pim_mxfp4_gemv
	mov	x8, #-64                        // =0xffffffffffffffc0
	mov	x9, x23
	.p2align	4, , 8
.LBB4_89:                               //   Parent Loop BB4_88 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	strb	wzr, [x9]
	add	x10, x9, #1, lsl #12            // =4096
	strb	w26, [x9, #64]
	add	x8, x8, #2, lsl #12             // =8192
	strb	w27, [x9, #128]
	cmp	x8, x24
	strb	w28, [x9, #192]
	strb	wzr, [x9, #256]
	strb	w26, [x9, #320]
	strb	w27, [x9, #384]
	strb	w28, [x9, #448]
	strb	wzr, [x9, #512]
	strb	w26, [x9, #576]
	strb	w27, [x9, #640]
	strb	w28, [x9, #704]
	strb	wzr, [x9, #768]
	strb	w26, [x9, #832]
	strb	w27, [x9, #896]
	strb	w28, [x9, #960]
	strb	wzr, [x9, #1024]
	strb	w26, [x9, #1088]
	strb	w27, [x9, #1152]
	strb	w28, [x9, #1216]
	strb	wzr, [x9, #1280]
	strb	w26, [x9, #1344]
	strb	w27, [x9, #1408]
	strb	w28, [x9, #1472]
	strb	wzr, [x9, #1536]
	strb	w26, [x9, #1600]
	strb	w27, [x9, #1664]
	strb	w28, [x9, #1728]
	strb	wzr, [x9, #1792]
	strb	w26, [x9, #1856]
	strb	w27, [x9, #1920]
	strb	w28, [x9, #1984]
	strb	wzr, [x9, #2048]
	strb	w26, [x9, #2112]
	strb	w27, [x9, #2176]
	strb	w28, [x9, #2240]
	strb	wzr, [x9, #2304]
	strb	w26, [x9, #2368]
	strb	w27, [x9, #2432]
	strb	w28, [x9, #2496]
	strb	wzr, [x9, #2560]
	strb	w26, [x9, #2624]
	strb	w27, [x9, #2688]
	strb	w28, [x9, #2752]
	strb	wzr, [x9, #2816]
	strb	w26, [x9, #2880]
	strb	w27, [x9, #2944]
	strb	w28, [x9, #3008]
	strb	wzr, [x9, #3072]
	strb	w26, [x9, #3136]
	strb	w27, [x9, #3200]
	strb	w28, [x9, #3264]
	strb	wzr, [x9, #3328]
	strb	w26, [x9, #3392]
	strb	w27, [x9, #3456]
	strb	w28, [x9, #3520]
	strb	wzr, [x9, #3584]
	strb	w26, [x9, #3648]
	strb	w27, [x9, #3712]
	strb	w28, [x9, #3776]
	strb	wzr, [x9, #3840]
	strb	w26, [x9, #3904]
	strb	w27, [x9, #3968]
	strb	w28, [x9, #4032]
	add	x9, x9, #2, lsl #12             // =8192
	strb	wzr, [x10]
	strb	w26, [x10, #64]
	strb	w27, [x10, #128]
	strb	w28, [x10, #192]
	strb	wzr, [x10, #256]
	strb	w26, [x10, #320]
	strb	w27, [x10, #384]
	strb	w28, [x10, #448]
	strb	wzr, [x10, #512]
	strb	w26, [x10, #576]
	strb	w27, [x10, #640]
	strb	w28, [x10, #704]
	strb	wzr, [x10, #768]
	strb	w26, [x10, #832]
	strb	w27, [x10, #896]
	strb	w28, [x10, #960]
	strb	wzr, [x10, #1024]
	strb	w26, [x10, #1088]
	strb	w27, [x10, #1152]
	strb	w28, [x10, #1216]
	strb	wzr, [x10, #1280]
	strb	w26, [x10, #1344]
	strb	w27, [x10, #1408]
	strb	w28, [x10, #1472]
	strb	wzr, [x10, #1536]
	strb	w26, [x10, #1600]
	strb	w27, [x10, #1664]
	strb	w28, [x10, #1728]
	strb	wzr, [x10, #1792]
	strb	w26, [x10, #1856]
	strb	w27, [x10, #1920]
	strb	w28, [x10, #1984]
	strb	wzr, [x10, #2048]
	strb	w26, [x10, #2112]
	strb	w27, [x10, #2176]
	strb	w28, [x10, #2240]
	strb	wzr, [x10, #2304]
	strb	w26, [x10, #2368]
	strb	w27, [x10, #2432]
	strb	w28, [x10, #2496]
	strb	wzr, [x10, #2560]
	strb	w26, [x10, #2624]
	strb	w27, [x10, #2688]
	strb	w28, [x10, #2752]
	strb	wzr, [x10, #2816]
	strb	w26, [x10, #2880]
	strb	w27, [x10, #2944]
	strb	w28, [x10, #3008]
	strb	wzr, [x10, #3072]
	strb	w26, [x10, #3136]
	strb	w27, [x10, #3200]
	strb	w28, [x10, #3264]
	strb	wzr, [x10, #3328]
	strb	w26, [x10, #3392]
	strb	w27, [x10, #3456]
	strb	w28, [x10, #3520]
	strb	wzr, [x10, #3584]
	strb	w26, [x10, #3648]
	strb	w27, [x10, #3712]
	strb	w28, [x10, #3776]
	strb	wzr, [x10, #3840]
	strb	w26, [x10, #3904]
	strb	w27, [x10, #3968]
	strb	w28, [x10, #4032]
	b.lo	.LBB4_89
// %bb.90:                              //   in Loop: Header=BB4_88 Depth=1
	ldr	w8, [sp, #268]                  // 4-byte Folded Reload
	add	w25, w25, #1
	cmp	w25, w8
	b.ne	.LBB4_88
.LBB4_91:
	add	x1, sp, #352
	mov	w0, #1                          // =0x1
	bl	clock_gettime
	mov	w10, #16384                     // =0x4000
	mov	x8, xzr
	ldr	q0, [sp, #352]
	movk	w10, #1, lsl #16
	str	wzr, [sp, #352]
	.p2align	4, , 8
.LBB4_92:                               // =>This Inner Loop Header: Depth=1
	add	x9, x21, x8
	add	x8, x8, #80
	cmp	x8, x10
	ldr	s1, [x9]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #4]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #8]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #12]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #16]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #20]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #24]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #28]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #32]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #36]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #40]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #44]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #48]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #52]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #56]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #60]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #64]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #68]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #72]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	ldr	s1, [x9, #76]
	ldr	s2, [sp, #352]
	fadd	s1, s1, s2
	str	s1, [sp, #352]
	b.ne	.LBB4_92
// %bb.93:
	ldr	q2, [sp, #336]                  // 16-byte Folded Reload
	mov	x0, x19
	zip2	v1.2d, v0.2d, v2.2d
	zip1	v0.2d, v0.2d, v2.2d
	ldr	q2, [sp, #144]                  // 16-byte Folded Reload
	scvtf	v1.2d, v1.2d
	scvtf	v0.2d, v0.2d
	fmla	v0.2d, v2.2d, v1.2d
	dup	v1.2d, v0.d[1]
	fsub	v0.2d, v0.2d, v1.2d
	str	q0, [sp, #336]                  // 16-byte Folded Spill
	ldr	s0, [sp, #352]
	bl	free
	mov	x0, x20
	bl	free
	mov	x0, x21
	bl	free
	mov	x0, x22
	bl	free
	mov	x0, x23
	bl	free
	ldr	w19, [sp, #268]                 // 4-byte Folded Reload
	mov	w8, #36700160                   // =0x2300000
	ldr	q1, [sp, #336]                  // 16-byte Folded Reload
	adrp	x0, pim_mxfp4_gemv_opt
	add	x0, x0, :lo12:pim_mxfp4_gemv_opt
	smull	x8, w19, w8
	mov	w1, w19
	ucvtf	d0, x8
	mov	x8, #145685290680320            // =0x848000000000
	movk	x8, #16686, lsl #48
	fdiv	d0, d0, d1
	fmov	d1, x8
	fdiv	d8, d0, d1
	bl	bench_dram
	adrp	x0, pim_mxfp4_gemv_opt_v2
	add	x0, x0, :lo12:pim_mxfp4_gemv_opt_v2
	mov	w1, w19
	fmov	d9, d0
	bl	bench_dram
	adrp	x0, pim_mxfp4_gemv_opt_v3
	add	x0, x0, :lo12:pim_mxfp4_gemv_opt_v3
	mov	w1, w19
	fmov	d10, d0
	bl	bench_dram
	adrp	x0, pim_mxfp4_gemv_opt_v4
	add	x0, x0, :lo12:pim_mxfp4_gemv_opt_v4
	mov	w1, w19
	fmov	d11, d0
	bl	bench_dram
	fmul	d1, d8, d13
	fmov	d12, d0
	fmov	d0, d8
	adrp	x0, .L.str.14
	add	x0, x0, :lo12:.L.str.14
	bl	printf
	fmul	d1, d9, d13
	fmov	d0, d9
	adrp	x0, .L.str.15
	add	x0, x0, :lo12:.L.str.15
	bl	printf
	fmul	d1, d10, d13
	fmov	d0, d10
	adrp	x0, .L.str.16
	add	x0, x0, :lo12:.L.str.16
	bl	printf
	fmul	d1, d11, d13
	fmov	d0, d11
	adrp	x0, .L.str.17
	add	x0, x0, :lo12:.L.str.17
	bl	printf
	fmul	d1, d12, d13
	fmov	d0, d12
	adrp	x0, .L.str.18
	add	x0, x0, :lo12:.L.str.18
	bl	printf
	mov	w0, #10                         // =0xa
	bl	putchar
	adrp	x0, .Lstr.26
	add	x0, x0, :lo12:.Lstr.26
	bl	puts
	adrp	x0, .Lstr.27
	add	x0, x0, :lo12:.Lstr.27
	bl	puts
	adrp	x0, .Lstr.28
	add	x0, x0, :lo12:.Lstr.28
	bl	puts
	adrp	x0, .Lstr.29
	add	x0, x0, :lo12:.Lstr.29
	bl	puts
	mov	w0, wzr
	add	sp, sp, #1392
	.cfi_def_cfa wsp, 160
	ldp	x20, x19, [sp, #144]            // 16-byte Folded Reload
	ldp	x22, x21, [sp, #128]            // 16-byte Folded Reload
	ldp	x24, x23, [sp, #112]            // 16-byte Folded Reload
	ldp	x26, x25, [sp, #96]             // 16-byte Folded Reload
	ldp	x28, x27, [sp, #80]             // 16-byte Folded Reload
	ldp	x29, x30, [sp, #64]             // 16-byte Folded Reload
	ldp	d9, d8, [sp, #48]               // 16-byte Folded Reload
	ldp	d11, d10, [sp, #32]             // 16-byte Folded Reload
	ldp	d13, d12, [sp, #16]             // 16-byte Folded Reload
	ldp	d15, d14, [sp], #160            // 16-byte Folded Reload
	.cfi_def_cfa_offset 0
	.cfi_restore w19
	.cfi_restore w20
	.cfi_restore w21
	.cfi_restore w22
	.cfi_restore w23
	.cfi_restore w24
	.cfi_restore w25
	.cfi_restore w26
	.cfi_restore w27
	.cfi_restore w28
	.cfi_restore w30
	.cfi_restore w29
	.cfi_restore b8
	.cfi_restore b9
	.cfi_restore b10
	.cfi_restore b11
	.cfi_restore b12
	.cfi_restore b13
	.cfi_restore b14
	.cfi_restore b15
	ret
.LBB4_94:
	.cfi_restore_state
	adrp	x0, .Lstr.32
	add	x0, x0, :lo12:.Lstr.32
	bl	puts
	mov	w0, #1                          // =0x1
	bl	exit
.LBB4_95:
	adrp	x0, .Lstr.33
	add	x0, x0, :lo12:.Lstr.33
	bl	puts
	mov	w0, #1                          // =0x1
	bl	exit
.Lfunc_end4:
	.size	main, .Lfunc_end4-main
	.cfi_endproc
                                        // -- End function
	.section	.rodata.cst16,"aM",@progbits,16
	.p2align	4, 0x0                          // -- Begin function bench_kernel
.LCPI5_0:
	.word	0                               // 0x0
	.word	1                               // 0x1
	.word	2                               // 0x2
	.word	3                               // 0x3
.LCPI5_1:
	.byte	0                               // 0x0
	.byte	1                               // 0x1
	.byte	2                               // 0x2
	.byte	3                               // 0x3
	.byte	4                               // 0x4
	.byte	5                               // 0x5
	.byte	6                               // 0x6
	.byte	7                               // 0x7
	.byte	8                               // 0x8
	.byte	9                               // 0x9
	.byte	10                              // 0xa
	.byte	11                              // 0xb
	.byte	12                              // 0xc
	.byte	13                              // 0xd
	.byte	14                              // 0xe
	.byte	15                              // 0xf
	.text
	.p2align	4
	.type	bench_kernel,@function
bench_kernel:                           // @bench_kernel
	.cfi_startproc
// %bb.0:
	sub	sp, sp, #128
	.cfi_def_cfa_offset 128
	str	d8, [sp, #32]                   // 8-byte Folded Spill
	stp	x29, x30, [sp, #40]             // 16-byte Folded Spill
	str	x27, [sp, #56]                  // 8-byte Folded Spill
	stp	x26, x25, [sp, #64]             // 16-byte Folded Spill
	stp	x24, x23, [sp, #80]             // 16-byte Folded Spill
	stp	x22, x21, [sp, #96]             // 16-byte Folded Spill
	stp	x20, x19, [sp, #112]            // 16-byte Folded Spill
	add	x29, sp, #40
	.cfi_def_cfa w29, 88
	.cfi_offset w19, -8
	.cfi_offset w20, -16
	.cfi_offset w21, -24
	.cfi_offset w22, -32
	.cfi_offset w23, -40
	.cfi_offset w24, -48
	.cfi_offset w25, -56
	.cfi_offset w26, -64
	.cfi_offset w27, -72
	.cfi_offset w30, -80
	.cfi_offset w29, -88
	.cfi_offset b8, -96
	.cfi_remember_state
	mov	x25, x0
	mov	w0, #14336                      // =0x3800
	mov	w19, w2
	mov	w20, w1
	bl	malloc
	mov	x21, x0
	sbfiz	x0, x20, #2, #32
	sxtw	x23, w20
	bl	malloc
	sbfiz	x8, x20, #11, #32
	mov	x22, x0
	sub	x27, x8, x23, lsl #8
	mov	x0, x27
	bl	malloc
	sbfiz	x8, x20, #7, #32
	mov	x23, x0
	sub	x26, x8, w20, sxtw #4
	mov	x0, x26
	bl	malloc
	cbz	x21, .LBB5_45
// %bb.1:
	cbz	x22, .LBB5_45
// %bb.2:
	cbz	x23, .LBB5_45
// %bb.3:
	mov	x24, x0
	cbz	x0, .LBB5_45
// %bb.4:
	mov	w8, #31153                      // =0x79b1
	mov	w10, #63736                     // =0xf8f8
	movk	w8, #40503, lsl #16
	mov	w9, #4660                       // =0x1234
	movk	w10, #22410, lsl #16
	movk	w9, #57005, lsl #16
	movi	v4.4s, #8
	adrp	x11, .LCPI5_0
	ldr	q0, [x11, :lo12:.LCPI5_0]
	dup	v1.4s, w8
	mov	w8, #19923                      // =0x4dd3
	dup	v3.4s, w10
	movk	w8, #4194, lsl #16
	mov	w10, #55050                     // =0xd70a
	dup	v2.4s, w9
	mov	w9, #1000                       // =0x3e8
	movk	w10, #15395, lsl #16
	dup	v5.4s, w8
	mov	x8, #-14336                     // =0xffffffffffffc800
	dup	v6.4s, w9
	dup	v7.4s, w10
	.p2align	4, , 8
.LBB5_5:                                // =>This Inner Loop Header: Depth=1
	mul	v16.4s, v0.4s, v1.4s
	add	x9, x21, x8
	adds	x8, x8, #32
	add	v0.4s, v0.4s, v4.4s
	add	v17.4s, v16.4s, v2.4s
	add	v16.4s, v16.4s, v3.4s
	umull2	v18.2d, v17.4s, v5.4s
	umull	v19.2d, v17.2s, v5.2s
	umull2	v20.2d, v16.4s, v5.4s
	umull	v21.2d, v16.2s, v5.2s
	uzp2	v18.4s, v19.4s, v18.4s
	uzp2	v19.4s, v21.4s, v20.4s
	ushr	v18.4s, v18.4s, #6
	ushr	v19.4s, v19.4s, #6
	mls	v17.4s, v18.4s, v6.4s
	mls	v16.4s, v19.4s, v6.4s
	ucvtf	v17.4s, v17.4s
	ucvtf	v16.4s, v16.4s
	fmul	v17.4s, v17.4s, v7.4s
	fmul	v16.4s, v16.4s, v7.4s
	str	q17, [x9, #14336]
	str	q16, [x9, #14352]
	b.ne	.LBB5_5
// %bb.6:
	cbz	w20, .LBB5_19
// %bb.7:
	movi	v0.16b, #55
	adrp	x8, .LCPI5_1
	ldr	q4, [x8, :lo12:.LCPI5_1]
	add	x9, x23, #16
	movi	v1.16b, #53
	movi	v2.16b, #165
	movi	v3.16b, #32
	.p2align	4, , 8
.LBB5_8:                                // =>This Inner Loop Header: Depth=1
	mul	v5.16b, v4.16b, v0.16b
	subs	x27, x27, #32
	add	v4.16b, v4.16b, v3.16b
	add	v6.16b, v5.16b, v1.16b
	add	v5.16b, v5.16b, v2.16b
	stp	q6, q5, [x9, #-16]
	add	x9, x9, #32
	b.ne	.LBB5_8
// %bb.9:
	cmp	x26, #32
	b.hs	.LBB5_13
// %bb.10:
	mov	x9, xzr
.LBB5_11:
	ldr	q3, [x8, :lo12:.LCPI5_1]
	dup	v2.16b, w9
	movi	v0.16b, #55
	sub	x8, x9, x26
	movi	v1.16b, #16
	add	x9, x24, x9
	orr	v2.16b, v2.16b, v3.16b
	.p2align	4, , 8
.LBB5_12:                               // =>This Inner Loop Header: Depth=1
	movi	v3.16b, #54
	adds	x8, x8, #16
	mla	v3.16b, v2.16b, v0.16b
	add	v2.16b, v2.16b, v1.16b
	str	q3, [x9], #16
	b.ne	.LBB5_12
	b	.LBB5_19
.LBB5_13:
	and	x9, x26, #0xffffffffffffffe0
	ldr	q0, [x8, :lo12:.LCPI5_1]
	movi	v1.16b, #55
	add	x10, x24, #16
	movi	v2.16b, #54
	mov	x11, x9
	movi	v3.16b, #166
	movi	v4.16b, #32
	.p2align	4, , 8
.LBB5_14:                               // =>This Inner Loop Header: Depth=1
	mul	v5.16b, v0.16b, v1.16b
	subs	x11, x11, #32
	add	v0.16b, v0.16b, v4.16b
	add	v6.16b, v5.16b, v2.16b
	add	v5.16b, v5.16b, v3.16b
	stp	q6, q5, [x10, #-16]
	add	x10, x10, #32
	b.ne	.LBB5_14
// %bb.15:
	cmp	x26, x9
	b.eq	.LBB5_19
// %bb.16:
	tbnz	w26, #4, .LBB5_11
// %bb.17:
	mov	w8, #55                         // =0x37
	mov	w10, #54                        // =0x36
	.p2align	4, , 8
.LBB5_18:                               // =>This Inner Loop Header: Depth=1
	madd	w11, w9, w8, w10
	strb	w11, [x24, x9]
	add	x9, x9, #1
	cmp	x26, x9
	b.ne	.LBB5_18
.LBB5_19:
	cmp	w26, #1
	b.lt	.LBB5_31
// %bb.20:
	ands	x8, x26, #0x7ffffff0
	b.eq	.LBB5_25
// %bb.21:
	cmp	x8, #32
	b.hs	.LBB5_28
// %bb.22:
	mov	x9, xzr
.LBB5_23:
	movi	v0.16b, #127
	sub	x8, x9, x8
	add	x9, x24, x9
	.p2align	4, , 8
.LBB5_24:                               // =>This Inner Loop Header: Depth=1
	ldr	q1, [x9]
	adds	x8, x8, #16
	and	v1.16b, v1.16b, v0.16b
	str	q1, [x9], #16
	b.ne	.LBB5_24
	b	.LBB5_31
.LBB5_25:
	mov	x9, xzr
.LBB5_26:
	add	x10, x24, x9
	sub	x8, x9, x8
	.p2align	4, , 8
.LBB5_27:                               // =>This Inner Loop Header: Depth=1
	ldrb	w9, [x10]
	adds	x8, x8, #1
	and	w9, w9, #0x7f
	strb	w9, [x10], #1
	b.lo	.LBB5_27
	b	.LBB5_31
.LBB5_28:
	and	x9, x26, #0x7fffffe0
	add	x10, x24, #16
	movi	v0.16b, #127
	mov	x11, x9
	.p2align	4, , 8
.LBB5_29:                               // =>This Inner Loop Header: Depth=1
	ldp	q1, q2, [x10, #-16]
	subs	x11, x11, #32
	and	v1.16b, v1.16b, v0.16b
	and	v2.16b, v2.16b, v0.16b
	stp	q1, q2, [x10, #-16]
	add	x10, x10, #32
	b.ne	.LBB5_29
// %bb.30:
	cmp	x8, x9
	b.ne	.LBB5_44
.LBB5_31:
	mov	x0, x22
	mov	x1, x21
	mov	x2, x23
	mov	x3, x24
	mov	w4, #3584                       // =0xe00
	mov	w5, w20
	mov	w6, #32                         // =0x20
	blr	x25
	mov	x0, x22
	mov	x1, x21
	mov	x2, x23
	mov	x3, x24
	mov	w4, #3584                       // =0xe00
	mov	w5, w20
	mov	w6, #32                         // =0x20
	blr	x25
	mov	x0, x22
	mov	x1, x21
	mov	x2, x23
	mov	x3, x24
	mov	w4, #3584                       // =0xe00
	mov	w5, w20
	mov	w6, #32                         // =0x20
	blr	x25
	mov	x0, x22
	mov	x1, x21
	mov	x2, x23
	mov	x3, x24
	mov	w4, #3584                       // =0xe00
	mov	w5, w20
	mov	w6, #32                         // =0x20
	blr	x25
	mov	x0, x22
	mov	x1, x21
	mov	x2, x23
	mov	x3, x24
	mov	w4, #3584                       // =0xe00
	mov	w5, w20
	mov	w6, #32                         // =0x20
	blr	x25
	add	x1, sp, #16
	mov	w0, #1                          // =0x1
	bl	clock_gettime
	ldr	q0, [sp, #16]
	cmp	w19, #1
	str	q0, [sp]                        // 16-byte Folded Spill
	b.lt	.LBB5_34
// %bb.32:
	mov	w26, w19
	.p2align	4, , 8
.LBB5_33:                               // =>This Inner Loop Header: Depth=1
	mov	x0, x22
	mov	x1, x21
	mov	x2, x23
	mov	x3, x24
	mov	w4, #3584                       // =0xe00
	mov	w5, w20
	mov	w6, #32                         // =0x20
	blr	x25
	subs	w26, w26, #1
	b.ne	.LBB5_33
.LBB5_34:
	add	x1, sp, #16
	mov	w0, #1                          // =0x1
	bl	clock_gettime
	ldr	q0, [sp, #16]
	cmp	w20, #1
	str	wzr, [sp, #16]
	b.lt	.LBB5_43
// %bb.35:
	mov	w10, w20
	cmp	w20, #4
	and	x8, x10, #0x3
	b.hs	.LBB5_37
// %bb.36:
	mov	x9, xzr
	cbnz	x8, .LBB5_40
	b	.LBB5_43
.LBB5_37:
	and	x11, x10, #0x7ffffffc
	mov	x9, xzr
	add	x10, x22, #8
	neg	x11, x11
	.p2align	4, , 8
.LBB5_38:                               // =>This Inner Loop Header: Depth=1
	ldur	s1, [x10, #-8]
	sub	x9, x9, #4
	ldr	s2, [sp, #16]
	cmp	x11, x9
	fadd	s1, s1, s2
	str	s1, [sp, #16]
	ldur	s1, [x10, #-4]
	ldr	s2, [sp, #16]
	fadd	s1, s1, s2
	str	s1, [sp, #16]
	ldr	s1, [x10]
	ldr	s2, [sp, #16]
	fadd	s1, s1, s2
	str	s1, [sp, #16]
	ldr	s1, [x10, #4]
	add	x10, x10, #16
	ldr	s2, [sp, #16]
	fadd	s1, s1, s2
	str	s1, [sp, #16]
	b.ne	.LBB5_38
// %bb.39:
	neg	x9, x9
	cbz	x8, .LBB5_43
.LBB5_40:
	ldr	s1, [x22, x9, lsl #2]
	cmp	x8, #1
	ldr	s2, [sp, #16]
	fadd	s1, s1, s2
	str	s1, [sp, #16]
	b.eq	.LBB5_43
// %bb.41:
	add	x9, x22, x9, lsl #2
	cmp	x8, #2
	ldr	s1, [x9, #4]
	ldr	s2, [sp, #16]
	fadd	s1, s1, s2
	str	s1, [sp, #16]
	b.eq	.LBB5_43
// %bb.42:
	ldr	s1, [x9, #8]
	ldr	s2, [sp, #16]
	fadd	s1, s1, s2
	str	s1, [sp, #16]
.LBB5_43:
	ldr	q2, [sp]                        // 16-byte Folded Reload
	mov	x8, #54933                      // =0xd695
	movk	x8, #59430, lsl #16
	mov	x0, x21
	movk	x8, #11787, lsl #32
	zip2	v1.2d, v0.2d, v2.2d
	movk	x8, #15889, lsl #48
	zip1	v0.2d, v0.2d, v2.2d
	dup	v2.2d, x8
	mov	x8, #4655596114794250240        // =0x409c000000000000
	scvtf	v1.2d, v1.2d
	scvtf	v0.2d, v0.2d
	fmla	v0.2d, v2.2d, v1.2d
	scvtf	d1, w20
	fmov	d2, x8
	dup	v3.2d, v0.d[1]
	fmul	d8, d1, d2
	fsub	v0.2d, v0.2d, v3.2d
	str	q0, [sp]                        // 16-byte Folded Spill
	ldr	s0, [sp, #16]
	bl	free
	mov	x0, x22
	bl	free
	mov	x0, x23
	bl	free
	mov	x0, x24
	bl	free
	scvtf	d0, w19
	ldr	q1, [sp]                        // 16-byte Folded Reload
	mov	x8, #145685290680320            // =0x848000000000
	movk	x8, #16686, lsl #48
	fmul	d0, d8, d0
	fdiv	d0, d0, d1
	fmov	d1, x8
	fdiv	d0, d0, d1
	.cfi_def_cfa wsp, 128
	ldp	x20, x19, [sp, #112]            // 16-byte Folded Reload
	ldp	x22, x21, [sp, #96]             // 16-byte Folded Reload
	ldp	x24, x23, [sp, #80]             // 16-byte Folded Reload
	ldp	x26, x25, [sp, #64]             // 16-byte Folded Reload
	ldp	x29, x30, [sp, #40]             // 16-byte Folded Reload
	ldr	x27, [sp, #56]                  // 8-byte Folded Reload
	ldr	d8, [sp, #32]                   // 8-byte Folded Reload
	add	sp, sp, #128
	.cfi_def_cfa_offset 0
	.cfi_restore w19
	.cfi_restore w20
	.cfi_restore w21
	.cfi_restore w22
	.cfi_restore w23
	.cfi_restore w24
	.cfi_restore w25
	.cfi_restore w26
	.cfi_restore w27
	.cfi_restore w30
	.cfi_restore w29
	.cfi_restore b8
	ret
.LBB5_44:
	.cfi_restore_state
	tbnz	w26, #4, .LBB5_23
	b	.LBB5_26
.LBB5_45:
	adrp	x0, .Lstr.32
	add	x0, x0, :lo12:.Lstr.32
	bl	puts
	mov	w0, #1                          // =0x1
	bl	exit
.Lfunc_end5:
	.size	bench_kernel, .Lfunc_end5-bench_kernel
	.cfi_endproc
                                        // -- End function
	.section	.rodata.cst16,"aM",@progbits,16
	.p2align	4, 0x0                          // -- Begin function bench_dram
.LCPI6_0:
	.byte	0                               // 0x0
	.byte	1                               // 0x1
	.byte	2                               // 0x2
	.byte	3                               // 0x3
	.byte	4                               // 0x4
	.byte	5                               // 0x5
	.byte	6                               // 0x6
	.byte	7                               // 0x7
	.byte	8                               // 0x8
	.byte	9                               // 0x9
	.byte	10                              // 0xa
	.byte	11                              // 0xb
	.byte	12                              // 0xc
	.byte	13                              // 0xd
	.byte	14                              // 0xe
	.byte	15                              // 0xf
.LCPI6_1:
	.word	0                               // 0x0
	.word	1                               // 0x1
	.word	2                               // 0x2
	.word	3                               // 0x3
	.text
	.p2align	4
	.type	bench_dram,@function
bench_dram:                             // @bench_dram
	.cfi_startproc
// %bb.0:
	sub	sp, sp, #144
	.cfi_def_cfa_offset 144
	stp	x29, x30, [sp, #48]             // 16-byte Folded Spill
	stp	x28, x27, [sp, #64]             // 16-byte Folded Spill
	stp	x26, x25, [sp, #80]             // 16-byte Folded Spill
	stp	x24, x23, [sp, #96]             // 16-byte Folded Spill
	stp	x22, x21, [sp, #112]            // 16-byte Folded Spill
	stp	x20, x19, [sp, #128]            // 16-byte Folded Spill
	add	x29, sp, #48
	.cfi_def_cfa w29, 96
	.cfi_offset w19, -8
	.cfi_offset w20, -16
	.cfi_offset w21, -24
	.cfi_offset w22, -32
	.cfi_offset w23, -40
	.cfi_offset w24, -48
	.cfi_offset w25, -56
	.cfi_offset w26, -64
	.cfi_offset w27, -72
	.cfi_offset w28, -80
	.cfi_offset w30, -88
	.cfi_offset w29, -96
	.cfi_remember_state
	mov	x24, x0
	mov	w0, #36700160                   // =0x2300000
	str	w1, [sp, #20]                   // 4-byte Folded Spill
	bl	malloc
	mov	x19, x0
	mov	w0, #14336                      // =0x3800
	bl	malloc
	mov	x21, x0
	mov	w0, #16384                      // =0x4000
	movk	w0, #1, lsl #16
	bl	malloc
	mov	x22, x0
	mov	w0, #2293760                    // =0x230000
	bl	malloc
	str	x19, [sp, #24]                  // 8-byte Folded Spill
	cbz	x19, .LBB6_21
// %bb.1:
	cbz	x21, .LBB6_21
// %bb.2:
	cbz	x22, .LBB6_21
// %bb.3:
	mov	x23, x0
	cbz	x0, .LBB6_21
// %bb.4:
	ldr	x9, [sp, #24]                   // 8-byte Folded Reload
	adrp	x8, .LCPI6_0
	ldr	q0, [x8, :lo12:.LCPI6_0]
	mov	w10, #36700160                  // =0x2300000
	movi	v1.16b, #55
	movi	v2.16b, #154
	add	x9, x9, #16
	movi	v3.16b, #10
	movi	v4.16b, #32
	.p2align	4, , 8
.LBB6_5:                                // =>This Inner Loop Header: Depth=1
	mul	v5.16b, v0.16b, v1.16b
	subs	x10, x10, #32
	add	v0.16b, v0.16b, v4.16b
	add	v6.16b, v5.16b, v2.16b
	add	v5.16b, v5.16b, v3.16b
	stp	q6, q5, [x9, #-16]
	add	x9, x9, #32
	b.ne	.LBB6_5
// %bb.6:
	mov	w9, #31153                      // =0x79b1
	mov	w11, #32861                     // =0x805d
	movk	w9, #40503, lsl #16
	mov	w10, #39321                     // =0x9999
	movk	w11, #14285, lsl #16
	movk	w10, #48879, lsl #16
	movi	v4.4s, #8
	adrp	x12, .LCPI6_1
	ldr	q0, [x12, :lo12:.LCPI6_1]
	dup	v1.4s, w9
	mov	w9, #19923                      // =0x4dd3
	dup	v3.4s, w11
	movk	w9, #4194, lsl #16
	mov	w11, #55050                     // =0xd70a
	dup	v2.4s, w10
	mov	w10, #1000                      // =0x3e8
	movk	w11, #15395, lsl #16
	dup	v5.4s, w9
	mov	x9, #-14336                     // =0xffffffffffffc800
	dup	v6.4s, w10
	dup	v7.4s, w11
	.p2align	4, , 8
.LBB6_7:                                // =>This Inner Loop Header: Depth=1
	mul	v16.4s, v0.4s, v1.4s
	add	x10, x21, x9
	adds	x9, x9, #32
	add	v0.4s, v0.4s, v4.4s
	add	v17.4s, v16.4s, v2.4s
	add	v16.4s, v16.4s, v3.4s
	umull2	v18.2d, v17.4s, v5.4s
	umull	v19.2d, v17.2s, v5.2s
	umull2	v20.2d, v16.4s, v5.4s
	umull	v21.2d, v16.2s, v5.2s
	uzp2	v18.4s, v19.4s, v18.4s
	uzp2	v19.4s, v21.4s, v20.4s
	ushr	v18.4s, v18.4s, #6
	ushr	v19.4s, v19.4s, #6
	mls	v17.4s, v18.4s, v6.4s
	mls	v16.4s, v19.4s, v6.4s
	ucvtf	v17.4s, v17.4s
	ucvtf	v16.4s, v16.4s
	fmul	v17.4s, v17.4s, v7.4s
	fmul	v16.4s, v16.4s, v7.4s
	str	q17, [x10, #14336]
	str	q16, [x10, #14352]
	b.ne	.LBB6_7
// %bb.8:
	movi	v0.16b, #55
	ldr	q4, [x8, :lo12:.LCPI6_0]
	movi	v1.16b, #155
	movi	v2.16b, #11
	movi	v3.16b, #32
	.p2align	4, , 8
.LBB6_9:                                // =>This Inner Loop Header: Depth=1
	mul	v5.16b, v4.16b, v0.16b
	add	x8, x23, x9
	add	x9, x9, #32
	add	v4.16b, v4.16b, v3.16b
	cmp	x9, #560, lsl #12               // =2293760
	add	v6.16b, v5.16b, v1.16b
	add	v5.16b, v5.16b, v2.16b
	stp	q6, q5, [x8]
	b.ne	.LBB6_9
// %bb.10:
	movi	v0.16b, #127
	mov	x8, xzr
	.p2align	4, , 8
.LBB6_11:                               // =>This Inner Loop Header: Depth=1
	add	x9, x23, x8
	add	x8, x8, #32
	cmp	x8, #560, lsl #12               // =2293760
	ldp	q1, q2, [x9]
	and	v1.16b, v1.16b, v0.16b
	and	v2.16b, v2.16b, v0.16b
	stp	q1, q2, [x9]
	b.ne	.LBB6_11
// %bb.12:
	mov	w0, #8388608                    // =0x800000
	bl	malloc
	cbz	x0, .LBB6_22
// %bb.13:
	ldr	x19, [sp, #24]                  // 8-byte Folded Reload
	mov	x25, x0
	mov	x0, x22
	mov	x1, x21
	mov	x3, x23
	mov	w4, #3584                       // =0xe00
	mov	x2, x19
	mov	w5, #20480                      // =0x5000
	mov	w6, #32                         // =0x20
	blr	x24
	mov	x0, x22
	mov	x1, x21
	mov	x2, x19
	mov	x3, x23
	mov	w4, #3584                       // =0xe00
	mov	w5, #20480                      // =0x5000
	mov	w6, #32                         // =0x20
	blr	x24
	mov	x0, x22
	mov	x1, x21
	mov	x2, x19
	mov	x3, x23
	mov	w4, #3584                       // =0xe00
	mov	w5, #20480                      // =0x5000
	mov	w6, #32                         // =0x20
	blr	x24
	sub	x1, x29, #16
	mov	w0, #1                          // =0x1
	bl	clock_gettime
	ldr	w8, [sp, #20]                   // 4-byte Folded Reload
	ldur	q0, [x29, #-16]
	cmp	w8, #1
	str	q0, [sp]                        // 16-byte Folded Spill
	b.lt	.LBB6_18
// %bb.14:
	mov	w27, wzr
	mov	w28, #64                        // =0x40
	mov	w26, #128                       // =0x80
	mov	w19, #192                       // =0xc0
	mov	w20, #8388544                   // =0x7fffc0
	.p2align	4, , 8
.LBB6_15:                               // =>This Loop Header: Depth=1
                                        //     Child Loop BB6_16 Depth 2
	mov	x0, x22
	mov	x1, x21
	ldr	x2, [sp, #24]                   // 8-byte Folded Reload
	mov	x3, x23
	mov	w4, #3584                       // =0xe00
	mov	w5, #20480                      // =0x5000
	mov	w6, #32                         // =0x20
	blr	x24
	mov	x8, #-64                        // =0xffffffffffffffc0
	mov	x9, x25
	.p2align	4, , 8
.LBB6_16:                               //   Parent Loop BB6_15 Depth=1
                                        // =>  This Inner Loop Header: Depth=2
	strb	wzr, [x9]
	add	x10, x9, #1, lsl #12            // =4096
	strb	w28, [x9, #64]
	add	x8, x8, #2, lsl #12             // =8192
	strb	w26, [x9, #128]
	cmp	x8, x20
	strb	w19, [x9, #192]
	strb	wzr, [x9, #256]
	strb	w28, [x9, #320]
	strb	w26, [x9, #384]
	strb	w19, [x9, #448]
	strb	wzr, [x9, #512]
	strb	w28, [x9, #576]
	strb	w26, [x9, #640]
	strb	w19, [x9, #704]
	strb	wzr, [x9, #768]
	strb	w28, [x9, #832]
	strb	w26, [x9, #896]
	strb	w19, [x9, #960]
	strb	wzr, [x9, #1024]
	strb	w28, [x9, #1088]
	strb	w26, [x9, #1152]
	strb	w19, [x9, #1216]
	strb	wzr, [x9, #1280]
	strb	w28, [x9, #1344]
	strb	w26, [x9, #1408]
	strb	w19, [x9, #1472]
	strb	wzr, [x9, #1536]
	strb	w28, [x9, #1600]
	strb	w26, [x9, #1664]
	strb	w19, [x9, #1728]
	strb	wzr, [x9, #1792]
	strb	w28, [x9, #1856]
	strb	w26, [x9, #1920]
	strb	w19, [x9, #1984]
	strb	wzr, [x9, #2048]
	strb	w28, [x9, #2112]
	strb	w26, [x9, #2176]
	strb	w19, [x9, #2240]
	strb	wzr, [x9, #2304]
	strb	w28, [x9, #2368]
	strb	w26, [x9, #2432]
	strb	w19, [x9, #2496]
	strb	wzr, [x9, #2560]
	strb	w28, [x9, #2624]
	strb	w26, [x9, #2688]
	strb	w19, [x9, #2752]
	strb	wzr, [x9, #2816]
	strb	w28, [x9, #2880]
	strb	w26, [x9, #2944]
	strb	w19, [x9, #3008]
	strb	wzr, [x9, #3072]
	strb	w28, [x9, #3136]
	strb	w26, [x9, #3200]
	strb	w19, [x9, #3264]
	strb	wzr, [x9, #3328]
	strb	w28, [x9, #3392]
	strb	w26, [x9, #3456]
	strb	w19, [x9, #3520]
	strb	wzr, [x9, #3584]
	strb	w28, [x9, #3648]
	strb	w26, [x9, #3712]
	strb	w19, [x9, #3776]
	strb	wzr, [x9, #3840]
	strb	w28, [x9, #3904]
	strb	w26, [x9, #3968]
	strb	w19, [x9, #4032]
	add	x9, x9, #2, lsl #12             // =8192
	strb	wzr, [x10]
	strb	w28, [x10, #64]
	strb	w26, [x10, #128]
	strb	w19, [x10, #192]
	strb	wzr, [x10, #256]
	strb	w28, [x10, #320]
	strb	w26, [x10, #384]
	strb	w19, [x10, #448]
	strb	wzr, [x10, #512]
	strb	w28, [x10, #576]
	strb	w26, [x10, #640]
	strb	w19, [x10, #704]
	strb	wzr, [x10, #768]
	strb	w28, [x10, #832]
	strb	w26, [x10, #896]
	strb	w19, [x10, #960]
	strb	wzr, [x10, #1024]
	strb	w28, [x10, #1088]
	strb	w26, [x10, #1152]
	strb	w19, [x10, #1216]
	strb	wzr, [x10, #1280]
	strb	w28, [x10, #1344]
	strb	w26, [x10, #1408]
	strb	w19, [x10, #1472]
	strb	wzr, [x10, #1536]
	strb	w28, [x10, #1600]
	strb	w26, [x10, #1664]
	strb	w19, [x10, #1728]
	strb	wzr, [x10, #1792]
	strb	w28, [x10, #1856]
	strb	w26, [x10, #1920]
	strb	w19, [x10, #1984]
	strb	wzr, [x10, #2048]
	strb	w28, [x10, #2112]
	strb	w26, [x10, #2176]
	strb	w19, [x10, #2240]
	strb	wzr, [x10, #2304]
	strb	w28, [x10, #2368]
	strb	w26, [x10, #2432]
	strb	w19, [x10, #2496]
	strb	wzr, [x10, #2560]
	strb	w28, [x10, #2624]
	strb	w26, [x10, #2688]
	strb	w19, [x10, #2752]
	strb	wzr, [x10, #2816]
	strb	w28, [x10, #2880]
	strb	w26, [x10, #2944]
	strb	w19, [x10, #3008]
	strb	wzr, [x10, #3072]
	strb	w28, [x10, #3136]
	strb	w26, [x10, #3200]
	strb	w19, [x10, #3264]
	strb	wzr, [x10, #3328]
	strb	w28, [x10, #3392]
	strb	w26, [x10, #3456]
	strb	w19, [x10, #3520]
	strb	wzr, [x10, #3584]
	strb	w28, [x10, #3648]
	strb	w26, [x10, #3712]
	strb	w19, [x10, #3776]
	strb	wzr, [x10, #3840]
	strb	w28, [x10, #3904]
	strb	w26, [x10, #3968]
	strb	w19, [x10, #4032]
	b.lo	.LBB6_16
// %bb.17:                              //   in Loop: Header=BB6_15 Depth=1
	ldr	w8, [sp, #20]                   // 4-byte Folded Reload
	add	w27, w27, #1
	cmp	w27, w8
	b.ne	.LBB6_15
.LBB6_18:
	sub	x1, x29, #16
	mov	w0, #1                          // =0x1
	bl	clock_gettime
	mov	w10, #16384                     // =0x4000
	mov	x8, xzr
	ldur	q0, [x29, #-16]
	movk	w10, #1, lsl #16
	stur	wzr, [x29, #-16]
	.p2align	4, , 8
.LBB6_19:                               // =>This Inner Loop Header: Depth=1
	add	x9, x22, x8
	add	x8, x8, #80
	cmp	x8, x10
	ldr	s1, [x9]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #4]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #8]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #12]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #16]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #20]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #24]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #28]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #32]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #36]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #40]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #44]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #48]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #52]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #56]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #60]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #64]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #68]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #72]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	ldr	s1, [x9, #76]
	ldur	s2, [x29, #-16]
	fadd	s1, s1, s2
	stur	s1, [x29, #-16]
	b.ne	.LBB6_19
// %bb.20:
	ldr	q2, [sp]                        // 16-byte Folded Reload
	mov	x8, #54933                      // =0xd695
	movk	x8, #59430, lsl #16
	movk	x8, #11787, lsl #32
	zip2	v1.2d, v0.2d, v2.2d
	movk	x8, #15889, lsl #48
	zip1	v0.2d, v0.2d, v2.2d
	dup	v2.2d, x8
	scvtf	v1.2d, v1.2d
	scvtf	v0.2d, v0.2d
	fmla	v0.2d, v2.2d, v1.2d
	dup	v1.2d, v0.d[1]
	fsub	v0.2d, v0.2d, v1.2d
	str	q0, [sp]                        // 16-byte Folded Spill
	ldur	s0, [x29, #-16]
	ldr	x0, [sp, #24]                   // 8-byte Folded Reload
	bl	free
	mov	x0, x21
	bl	free
	mov	x0, x22
	bl	free
	mov	x0, x23
	bl	free
	mov	x0, x25
	bl	free
	ldr	w9, [sp, #20]                   // 4-byte Folded Reload
	mov	w8, #36700160                   // =0x2300000
	ldr	q1, [sp]                        // 16-byte Folded Reload
	smull	x8, w9, w8
	ucvtf	d0, x8
	mov	x8, #145685290680320            // =0x848000000000
	movk	x8, #16686, lsl #48
	fdiv	d0, d0, d1
	fmov	d1, x8
	fdiv	d0, d0, d1
	.cfi_def_cfa wsp, 144
	ldp	x20, x19, [sp, #128]            // 16-byte Folded Reload
	ldp	x22, x21, [sp, #112]            // 16-byte Folded Reload
	ldp	x24, x23, [sp, #96]             // 16-byte Folded Reload
	ldp	x26, x25, [sp, #80]             // 16-byte Folded Reload
	ldp	x28, x27, [sp, #64]             // 16-byte Folded Reload
	ldp	x29, x30, [sp, #48]             // 16-byte Folded Reload
	add	sp, sp, #144
	.cfi_def_cfa_offset 0
	.cfi_restore w19
	.cfi_restore w20
	.cfi_restore w21
	.cfi_restore w22
	.cfi_restore w23
	.cfi_restore w24
	.cfi_restore w25
	.cfi_restore w26
	.cfi_restore w27
	.cfi_restore w28
	.cfi_restore w30
	.cfi_restore w29
	ret
.LBB6_21:
	.cfi_restore_state
	adrp	x0, .Lstr.32
	add	x0, x0, :lo12:.Lstr.32
	bl	puts
	mov	w0, #1                          // =0x1
	bl	exit
.LBB6_22:
	adrp	x0, .Lstr.33
	add	x0, x0, :lo12:.Lstr.33
	bl	puts
	mov	w0, #1                          // =0x1
	bl	exit
.Lfunc_end6:
	.size	bench_dram, .Lfunc_end6-bench_dram
	.cfi_endproc
                                        // -- End function
	.p2align	4                               // -- Begin function mt_worker
	.type	mt_worker,@function
mt_worker:                              // @mt_worker
	.cfi_startproc
// %bb.0:
	stp	x29, x30, [sp, #-16]!           // 16-byte Folded Spill
	.cfi_def_cfa_offset 16
	mov	x29, sp
	.cfi_def_cfa w29, 16
	.cfi_offset w30, -8
	.cfi_offset w29, -16
	ldr	w4, [x0, #40]
	ldp	x9, x10, [x0, #24]
	ldp	w6, w8, [x0, #44]
	adds	w12, w4, #31
	add	w13, w4, #62
	ldp	x15, x14, [x0]
                                        // kill: def $w8 killed $w8 def $x8
	add	w11, w4, w4, lsr #31
	csel	w12, w13, w12, lt
	sxtw	x8, w8
	asr	w11, w11, #1
	ldr	w13, [x0, #52]
	asr	w12, w12, #5
	smaddl	x2, w8, w11, x9
	ldr	x1, [x0, #16]
	nop
	smaddl	x3, w8, w12, x10
	add	x0, x14, x8, lsl #2
	sub	w5, w13, w8
	blr	x15
	mov	x0, xzr
	.cfi_def_cfa wsp, 16
	ldp	x29, x30, [sp], #16             // 16-byte Folded Reload
	.cfi_def_cfa_offset 0
	.cfi_restore w30
	.cfi_restore w29
	ret
.Lfunc_end7:
	.size	mt_worker, .Lfunc_end7-mt_worker
	.cfi_endproc
                                        // -- End function
	.type	PIM_E2M1,@object                // @PIM_E2M1
	.section	.rodata,"a",@progbits
	.p2align	2, 0x0
PIM_E2M1:
	.word	0x00000000                      // float 0
	.word	0x3f000000                      // float 0.5
	.word	0x3f800000                      // float 1
	.word	0x3fc00000                      // float 1.5
	.word	0x40000000                      // float 2
	.word	0x40400000                      // float 3
	.word	0x40800000                      // float 4
	.word	0x40c00000                      // float 6
	.word	0x80000000                      // float -0
	.word	0xbf000000                      // float -0.5
	.word	0xbf800000                      // float -1
	.word	0xbfc00000                      // float -1.5
	.word	0xc0000000                      // float -2
	.word	0xc0400000                      // float -3
	.word	0xc0800000                      // float -4
	.word	0xc0c00000                      // float -6
	.size	PIM_E2M1, 64

	.type	.L__const.main.batch,@object    // @__const.main.batch
	.p2align	2, 0x0
.L__const.main.batch:
	.word	1                               // 0x1
	.word	8                               // 0x8
	.word	320                             // 0x140
	.size	.L__const.main.batch, 12

	.type	.L.str,@object                  // @.str
.L.str:
	.asciz	"1 expert"
	.size	.L.str, 9

	.type	.L.str.1,@object                // @.str.1
.L.str.1:
	.asciz	"8 experts (1 layer)"
	.size	.L.str.1, 20

	.type	.L.str.2,@object                // @.str.2
.L.str.2:
	.asciz	"320 (40 layers top-8)"
	.size	.L.str.2, 22

	.type	.L__const.main.bname.rel,@object // @__const.main.bname.rel
	.p2align	2, 0x0
.L__const.main.bname.rel:
	.word	.L.str-.L__const.main.bname.rel
	.word	.L.str.1-.L__const.main.bname.rel
	.word	.L.str.2-.L__const.main.bname.rel
	.size	.L__const.main.bname.rel, 12

	.type	.L.str.3,@object                // @.str.3
	.section	.rodata.str1.1,"aMS",@progbits,1
.L.str.3:
	.asciz	"bench_gemv v2 \342\200\224 \346\266\210\351\231\244\346\227\247\347\211\210\344\274\252\345\275\261 (reps=%d)\n"
	.size	.L.str.3, 48

	.type	.L.str.5,@object                // @.str.5
.L.str.5:
	.asciz	"== %s (%dx%d, %d rows, pk=%.1f KB) ==\n"
	.size	.L.str.5, 39

	.type	.L.str.6,@object                // @.str.6
.L.str.6:
	.asciz	"  reference : %7.1f MB/s  (%6.1f GFLOP/s)  x1.00\n"
	.size	.L.str.6, 50

	.type	.L.str.7,@object                // @.str.7
.L.str.7:
	.asciz	"  opt(f32)  : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n"
	.size	.L.str.7, 50

	.type	.L.str.8,@object                // @.str.8
.L.str.8:
	.asciz	"  v2(unpack): %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n"
	.size	.L.str.8, 50

	.type	.L.str.9,@object                // @.str.9
.L.str.9:
	.asciz	"  v3(flat8) : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n"
	.size	.L.str.9, 50

	.type	.L.str.10,@object               // @.str.10
.L.str.10:
	.asciz	"  v4(neon)  : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n"
	.size	.L.str.10, 50

	.type	.L.str.11,@object               // @.str.11
.L.str.11:
	.asciz	"  opt x8t   : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n"
	.size	.L.str.11, 50

	.type	.L.str.14,@object               // @.str.14
.L.str.14:
	.asciz	"  reference : %7.1f MB/s  (%6.1f GFLOP/s)\n"
	.size	.L.str.14, 43

	.type	.L.str.15,@object               // @.str.15
.L.str.15:
	.asciz	"  opt(f32)  : %7.1f MB/s  (%6.1f GFLOP/s)\n"
	.size	.L.str.15, 43

	.type	.L.str.16,@object               // @.str.16
.L.str.16:
	.asciz	"  v2(unpack): %7.1f MB/s  (%6.1f GFLOP/s)\n"
	.size	.L.str.16, 43

	.type	.L.str.17,@object               // @.str.17
.L.str.17:
	.asciz	"  v3(flat8) : %7.1f MB/s  (%6.1f GFLOP/s)\n"
	.size	.L.str.17, 43

	.type	.L.str.18,@object               // @.str.18
.L.str.18:
	.asciz	"  v4(neon)  : %7.1f MB/s  (%6.1f GFLOP/s)\n"
	.size	.L.str.18, 43

	.type	.Lstr,@object                   // @str
	.section	.rodata.str1.4,"aMS",@progbits,1
	.p2align	2, 0x0
.Lstr:
	.asciz	"\346\211\213\346\234\272 DRAM \345\270\246\345\256\275\345\242\231: ~6900 MB/s (memcpy \345\256\236\346\265\213)\n"
	.size	.Lstr, 51

	.type	.Lstr.25,@object                // @str.25
	.p2align	2, 0x0
.Lstr.25:
	.asciz	"== DRAM-bound (320 rows, pk=36MB, flush between reps) =="
	.size	.Lstr.25, 57

	.type	.Lstr.26,@object                // @str.26
	.p2align	2, 0x0
.Lstr.26:
	.asciz	"\350\247\243\350\257\273:"
	.size	.Lstr.26, 8

	.type	.Lstr.27,@object                // @str.27
	.p2align	2, 0x0
.Lstr.27:
	.asciz	"  - \350\213\245 opt>>reference: \347\223\266\351\242\210\345\234\250 compute (\345\217\202\350\200\203 double \347\264\257\345\212\240\346\205\242)"
	.size	.Lstr.27, 68

	.type	.Lstr.28,@object                // @str.28
	.p2align	2, 0x0
.Lstr.28:
	.asciz	"  - \350\213\245 opt\342\211\210reference \344\270\224\346\216\245\350\277\221 memcpy \345\270\246\345\256\275: \347\223\266\351\242\210\345\234\250 DRAM"
	.size	.Lstr.28, 64

	.type	.Lstr.29,@object                // @str.29
	.p2align	2, 0x0
.Lstr.29:
	.asciz	"  - \350\213\245 DRAM-bound \350\277\234\344\275\216\344\272\216 memcpy: \345\274\225\346\223\216\345\234\250 DRAM \344\276\247\344\271\237\346\234\211\344\274\230\345\214\226\347\251\272\351\227\264"
	.size	.Lstr.29, 74

	.type	.Lstr.32,@object                // @str.32
	.p2align	2, 0x0
.Lstr.32:
	.asciz	"OOM"
	.size	.Lstr.32, 4

	.type	.Lstr.33,@object                // @str.33
	.p2align	2, 0x0
.Lstr.33:
	.asciz	"OOM dummy"
	.size	.Lstr.33, 10

	.type	.L_MergedGlobals,@object        // @_MergedGlobals
	.local	.L_MergedGlobals
	.comm	.L_MergedGlobals,2052,4
g_flat_init = .L_MergedGlobals
	.size	g_flat_init, 1
g_flat = .L_MergedGlobals+4
	.size	g_flat, 2048
	.ident	"clang version 21.1.8"
	.section	".note.GNU-stack","",@progbits
