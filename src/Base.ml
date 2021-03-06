
module type Monoid = sig
  type t

  val empty : t

  val append : t -> t -> t

  val (++) : t -> t -> t
end

module Monoid = struct
  module type Base = sig
    type t

    val empty : t

    val append : t -> t -> t
  end

  module Make(B : Base) : Monoid with type t := B.t = struct
    include B

    let (++) = append
  end
end

let (++) = List.append

