defmodule ReaxtError do
  defexception [:message,:props,:js_stack]
  def exception({:handler_error,error,stack}) do
    %ReaxtError{message: "JS Exception : #{error}", js_stack: (stack && parse_stack(stack))}
  end
  def exception({:render_error,error,stack,props}) do
    %ReaxtError{message: "JS Exception : #{error}", props: props, js_stack: (stack && parse_stack(stack))}
  end

  defp parse_stack(stack) do
    Regex.scan(~r/at (.*) \((.*):([0-9]*):[0-9]*\)/,stack)
    |> Enum.map(fn [_,function,url,line]->
      if String.contains?(url,"server.js") and !(function in ["Port.next_term","Socket.read_term"]) do
        {line,_} = Integer.parse(line)
        {JS,:"#{function}",0,file: '#{WebPack.Util.web_priv}/server.js', line: line}
      end
    end)
    |> Enum.filter(&!is_nil(&1))
  end
end
defmodule Reaxt do
  alias :poolboy, as: Pool
  require Logger

  def render_result(module,data), do:
    render_result(module,data, dyn_handler: false)
  def render_result(module,data,opts) when not is_tuple(module), do:
    render_result({module,nil},data,opts)
  def render_result({module,submodule},data,opts) do
    req = if opts[:dyn_handler], do: :render_dyn_tpl, else: :render_tpl
    Pool.transaction(:react_pool,fn worker->
      GenServer.call(worker,{req,module,submodule,data})
    end)
  end

  def render!(module,data,opts \\ [dyn_handler: false]) do
    case render_result(module,data,opts) do
      {:ok,res}->res
      {:error,err}->
        try do raise(ReaxtError,err)
        rescue ex->
          [_|stack] = System.stacktrace
          reraise ex, ((ex.js_stack || []) ++ stack)
        end
    end
  end
  
  def render(module,data,opts \\ [dyn_handler: false]) do
    try do 
      render!(module,data,opts) 
    rescue
      ex->
        case ex do
          %{props: props} when is_binary(props)->
            Logger.error(Exception.message(ex))
            %{css: "",html: "", init_props: props}
          _ -> 
            reraise ex, System.stacktrace
        end
    end
  end

  def start_link([]) do
    Exos.Proc.start_link("node server",nil,[cd: '#{WebPack.Util.web_priv}'])
  end

  defmodule App do
    use Application
    def start(_,_) do
      WebPack.Util.build_stats
      Supervisor.start_link(App.Sup,[], name: App.Sup)
    end
    defmodule Sup do
      use Supervisor
      def init([]) do
        dev_workers = if Code.ensure_loaded?(Mix) and Mix.env == :dev, 
           do: [worker(WebPack.Compiler,[]),worker(WebPack.EventManager,[])], else: []
        supervise(dev_workers ++ [
          Pool.child_spec(:react,[worker_module: Reaxt,size: 1, max_overflow: 10, name: {:local,:react_pool}], [])
        ], strategy: :one_for_one)
      end
    end
  end
end
