(*
 * Computing execution bounds using partial order reduction.
 *
 * Igor Konnov, 2014
 *)

open Printf

open Accums
open Debug
open SymbSkel
open Plugin
open PorBounds

class por_bounds_plugin_t (plugin_name: string)
        (sk_plugin: SymbSkelPlugin.symb_skel_plugin_t) =
    object(self)
        inherit analysis_plugin_t plugin_name

        method transform rt =
            let dom = rt#caches#analysis#get_pia_dom in
            let dom_size = dom#length in
            List.iter
                (fun s -> ignore (PorBounds.compute_diam rt#solver dom_size s))
                sk_plugin#skels;
            self#get_input0

        method update_runtime rt =
            ()
    end

