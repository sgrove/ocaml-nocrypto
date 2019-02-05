include Nocrypto_uncommon
module Rng = NoRng
module Hash = Nocrypto_hash

module Repr = struct

  let (lsr) = Z.shift_right
  let (lsl) = Z.shift_left
  let pp = Z.pp_print

  let (ws, ws0, ws1) = Sys.(word_size, word_size - 1, word_size - 2)

  let bit_size i =
    let slack = (Z.size i - 1) * ws in
    let tip   = Z.(i lsr slack) in
    match Z.(testbit tip ws0, testbit tip ws1) with
        true, _ -> slack + ws
      | _, true -> slack + ws - 1
      | _       -> slack + (Z.to_int tip |> Rng.Private.bit_size)

  let of_cstruct_be ?bits cs =
    let open Cstruct in
    let open BE in
    let rec loop acc i = function
      | b when b >= 64 ->
          let x = get_uint64 cs i in
          let x = Z.of_int64 Int64.(shift_right_logical x 8) in
          loop Z.(x + acc lsl 56) (i + 7) (b - 56)
      | b when b >= 32 ->
          let x = get_uint32 cs i in
          let x = Z.of_int32 Int32.(shift_right_logical x 8) in
          loop Z.(x + acc lsl 24) (i + 3) (b - 24)
      | b when b >= 16 ->
          let x = Z.of_int (get_uint16 cs i) in
          loop Z.(x + acc lsl 16) (i + 2) (b - 16)
      | b when b >= 8  ->
          let x = Z.of_int (get_uint8 cs i) in
          loop Z.(x + acc lsl 8 ) (i + 1) (b - 8 )
      | b when b > 0   ->
          let x = get_uint8 cs i and b' = 8 - b in
          Z.(of_int x lsr b' + acc lsl b)
      | _              -> acc in
    loop Z.zero 0 @@ match bits with
      | None   -> Cstruct.len cs * 8
      | Some b -> imin b (Cstruct.len cs * 8)

  let byte1 = Z.of_int64 0xffL
  and byte2 = Z.of_int64 0xffffL
  and byte3 = Z.of_int64 0xffffffL
  and byte7 = Z.of_int64 0xffffffffffffffL

  let into_cstruct_be n cs =
    let open Cstruct in
    let open BE in

    let rec write n = function
      | i when i >= 7 ->
          set_uint64 cs (i - 7) Z.(to_int64 (n land byte7)) ;
          write Z.(n lsr 56) (i - 7)
      | i when i >= 3 ->
          set_uint32 cs (i - 3) Z.(to_int32 (n land byte3)) ;
          write Z.(n lsr 24) (i - 3)
      | i when i >= 1 ->
          set_uint16 cs (i - 1) Z.(to_int (n land byte2)) ;
          write Z.(n lsr 16) (i - 2)
      | 0 -> set_uint8 cs 0 Z.(to_int (n land byte1)) ;
      | _ -> ()
    in
    write n (len cs - 1)

  let to_cstruct_be ?size n =
    let cs = Cstruct.create_unsafe @@ match size with
      | Some s -> imax 0 s
      | None   -> bit_size n // 8 in
    ( into_cstruct_be n cs ; cs )
end

(* Handbook of Applied Cryptography, Table 4.4:
 * Miller-Rabin rounds for composite probability <= 1/2^80. *)
let pseudoprime z =
  let i = match Repr.bit_size z with
    | i when i >= 1300 ->  2
    | i when i >=  850 ->  3
    | i when i >=  650 ->  4
    | i when i >=  350 ->  8
    | i when i >=  250 -> 12
    | i when i >=  150 -> 18
    | _                -> 27 in
  Z.probab_prime z i <> 0

module RngZ = struct

  include NoRng.Arith (struct
    type t = Z.t
    let of_cstruct_be ~bits cs = Repr.of_cstruct_be ~bits cs
    let bit_size = Repr.bit_size
    let zero = Z.zero and one = Z.one
    let (+) = Z.(+) and (-) = Z.(-)
    let pp = Z.pp_print
  end)

  (* Invalid combinations of ~bits and ~msb will loop forever, but there is no
  * way to quickly determine upfront whether there are any primes in the
  * interval.
  * XXX Probability is distributed as inter-prime gaps. So?
  *)
  let rec prime ?g ?(msb = 1) bits =
    let p = Z.(nextprime @@ gen_bits ?g ~msb bits) in
    if p < Z.(one lsl bits) then p else prime ?g ~msb bits

  (* XXX Add ~msb param for p? *)
  let rec safe_prime ?g bits =
    let q = prime ?g ~msb:1 (bits - 1) in
    let p = Z.(q * ~$2 + ~$1) in
    if pseudoprime p then (q, p) else safe_prime ?g bits

  (*     |+ Pocklington primality test specialized for `a = 2`. +|
    if Z.(gcd (of_int 3) p = one) then (q, p)
    else safe_prime ?g ~bits *)
end

(* strip_factor ~f x = (s, t), where x = f^s t *)
let strip_factor ~f x =
  let rec go n x =
    let (x1, r) = Z.div_rem x f in
    if r = Z.zero then go (succ n) x1 else (n, x) in
  if Z.(~$2) <= f then go 0 x else
    invalid_arg "factor_count: f: %a" Z.pp_print f
