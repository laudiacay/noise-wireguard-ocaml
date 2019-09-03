open Core
open Or_error.Let_syntax

type%cstruct t =
  { (* CR crichoux: should you add a mutex here? *)
    mac1_key: uint8_t [@len 32]
  ; mac2_cookie: uint8_t [@len 32]
  ; mac2_cookie_set: uint8_t [@len 12]
  ; mac2_has_last_mac1: uint8_t
  ; mac2_last_mac1: uint8_t [@len 32]
  ; encryption_key: uint8_t [@len 32] }
[@@little_endian]

type t = Cstruct.t

let blit_t_mac1_key = Misc.make_nice_blit blit_t_mac1_key
let blit_t_encryption_key = Misc.make_nice_blit blit_t_encryption_key
let blit_t_mac2_cookie_set = Misc.make_nice_blit blit_t_mac2_cookie_set
let blit_t_mac2_cookie = Misc.make_nice_blit blit_t_mac2_cookie
let blit_t_mac2_last_mac1 = Misc.make_nice_blit blit_t_mac2_last_mac1

let get_t_mac2_cookie_set t =
  get_t_mac2_cookie_set t |> Cstruct.to_bytes |> Tai64n.of_bytes

let get_t_mac2_cookie t =
  get_t_mac2_cookie t |> Cstruct.to_bytes |> Crypto.Shared.of_bytes

let get_t_mac2_has_last_mac1 t : bool =
  match get_t_mac2_has_last_mac1 t with 1 -> true | _ -> false

let set_t_mac2_has_last_mac1 t value : unit =
  let value = if value then 1 else 0 in
  set_t_mac2_has_last_mac1 t value

let get_t_mac1_key t =
  get_t_mac1_key t |> Cstruct.to_bytes |> Crypto.Shared.of_bytes

let get_t_encryption_key t =
  get_t_encryption_key t |> Cstruct.to_bytes |> Crypto.Shared.of_bytes

let init pk : t Or_error.t =
  let ckr = Cstruct.create sizeof_t in
  let%map mac1_key, mac2_encryption_key, time = Misc.init_constants pk in
  blit_t_mac1_key ckr mac1_key ;
  blit_t_encryption_key ckr mac2_encryption_key ;
  blit_t_mac2_cookie_set ckr time ;
  ckr

(* CR crichoux: write tESTS *)
let consume_reply ~t ~(msg : Noise.Message.cookie_reply) : unit Or_error.t =
  if not (get_t_mac2_has_last_mac1 t) then
    Or_error.error_string "no last mac1 for cookie reply"
  else
    let%map cookie =
      Crypto.xaead_encrypt ~key:(get_t_encryption_key t)
        ~nonce:(Noise.Message.get_cookie_reply_nonce msg)
        ~message:(Noise.Message.get_cookie_reply_cookie msg)
        ~auth_text:(get_t_mac2_last_mac1 t |> Cstruct.to_bytes) in
    blit_t_mac2_cookie_set t (Tai64n.now () |> Tai64n.to_bytes) ;
    blit_t_mac2_cookie t cookie

(* CR crichoux: write tESTS *)
let add_macs ~t ~(msg : Noise.Message.handshake_response) : unit Or_error.t =
  let msg_cstruct = Noise.Message.handshake_response_to_cstruct msg in
  let (msg_alpha, _), (msg_beta, _) = Misc.get_macs msg_cstruct in
  let%bind mac1 =
    Crypto.mac ~key:(get_t_mac1_key t) ~input:(Cstruct.to_bytes msg_alpha)
  in
  Misc.set_mac1 ~msg:msg_cstruct ~mac1 ;
  blit_t_mac2_last_mac1 t mac1 ;
  set_t_mac2_has_last_mac1 t true ;
  if
    Time_ns.Span.(
      Tai64n.since (get_t_mac2_cookie_set t) > Misc.cookie_refresh_time)
  then Or_error.return ()
  else
    let%map mac2 =
      Crypto.mac ~key:(get_t_mac2_cookie t) ~input:(Cstruct.to_bytes msg_beta)
    in
    Misc.set_mac2 ~msg:msg_cstruct ~mac2