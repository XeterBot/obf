local config = require("config")
local Ast = require("prometheus.ast")
local Enums = require("prometheus.enums")
local util = require("prometheus.util")
local Parser = require("prometheus.parser")
local Unparser = require("prometheus.unparser")
local logger = require("logger")

local NameGenerators = require("prometheus.namegenerators")
local Steps = require("prometheus.steps")

local isWindows = package and package.config and type(package.config) == "string" and package.config:sub(1, 1) == "\\"

local function gettime()
    return isWindows and os.clock() or os.time()
end

local Pipeline = {
    NameGenerators = NameGenerators,
    Steps = Steps,
    DefaultSettings = {
        LuaVersion = Enums.LuaVersion.LuaU,
        PrettyPrint = false,
        Seed = 0,
        VarNamePrefix = ""
    }
}

function Pipeline:new(settings)
    local luaVersion = settings.luaVersion or settings.LuaVersion or self.DefaultSettings.LuaVersion
    local conventions = Enums.Conventions[luaVersion]

    if not conventions then
        logger:error('Lua Version "%s" is not recognized! Use: "%s"', luaVersion, table.concat(util.keys(Enums.Conventions), '", "'))
    end

    local pipeline = {
        LuaVersion = luaVersion,
        PrettyPrint = settings.PrettyPrint or self.DefaultSettings.PrettyPrint,
        VarNamePrefix = settings.VarNamePrefix or self.DefaultSettings.VarNamePrefix,
        Seed = settings.Seed or 0,
        parser = Parser:new({ LuaVersion = luaVersion }),
        unparser = Unparser:new({ LuaVersion = luaVersion, PrettyPrint = settings.PrettyPrint, Highlight = settings.Highlight }),
        namegenerator = NameGenerators.MangledShuffled,
        conventions = conventions,
        steps = {}
    }

    setmetatable(pipeline, self)
    self.__index = self
    return pipeline
end

function Pipeline:fromConfig(config)
    config = config or {}
    local pipeline = self:new({
        LuaVersion = config.LuaVersion or Enums.LuaVersion.Lua51,
        PrettyPrint = config.PrettyPrint or false,
        VarNamePrefix = config.VarNamePrefix or "",
        Seed = config.Seed or 0
    })

    pipeline:setNameGenerator(config.NameGenerator or "MangledShuffled")

    for _, step in ipairs(config.Steps or {}) do
        local constructor = self.Steps[step.Name]
        if not constructor then
            logger:error('Step "%s" not found!', step.Name)
        end
        pipeline:addStep(constructor:new(step.Settings or {}))
    end

    return pipeline
end

function Pipeline:addStep(step)
    self.steps[#self.steps + 1] = step
end

function Pipeline:resetSteps()
    self.steps = {}
end

function Pipeline:getSteps()
    return self.steps
end

function Pipeline:setLuaVersion(luaVersion)
    local conventions = Enums.Conventions[luaVersion]
    if not conventions then
        logger:error('Lua Version "%s" is not recognized! Use: "%s"', luaVersion, table.concat(util.keys(Enums.Conventions), '", "'))
    end

    self.parser = Parser:new({ luaVersion = luaVersion })
    self.unparser = Unparser:new({ luaVersion = luaVersion })
    self.conventions = conventions
end

function Pipeline:getLuaVersion()
    return self.LuaVersion
end

function Pipeline:setNameGenerator(nameGenerator)
    if type(nameGenerator) == "string" then
        nameGenerator = self.NameGenerators[nameGenerator]
    end

    if type(nameGenerator) == "function" or type(nameGenerator) == "table" then
        self.namegenerator = nameGenerator
    else
        logger:error("Invalid NameGenerator: must be a function or name string.")
    end
end

function Pipeline:apply(code, filename)
    local startTime = gettime()
    filename = filename or "Anonymous Script"
    logger:info('Applying Obfuscation Pipeline to "%s" ...', filename)

    if self.Seed > 0 then
        math.randomseed(self.Seed)
    else
        math.randomseed(gettime())
    end

    logger:info("Parsing ...")
    local ast = self.parser:parse(code)
    logger:info("Parsing Done.")

    for _, step in ipairs(self.steps) do
        logger:info('Applying Step "%s" ...', step.Name or "Unnamed")
        local newAst = step:apply(ast, self)
        if type(newAst) == "table" then
            ast = newAst
        end
    end

    self:renameVariables(ast)

    code = self:unparse(ast)

    local timeDiff = gettime() - startTime
    logger:info("Obfuscation Done in %.2f seconds.", timeDiff)

    return code
end

function Pipeline:unparse(ast)
    logger:info("Generating Code ...")
    local unparsed = self.unparser:unparse(ast)
    logger:info("Code Generation Done.")
    return unparsed
end

function Pipeline:renameVariables(ast)
    logger:info("Renaming Variables ...")

    local generatorFunction = self.namegenerator or self.NameGenerators.mangled
    if type(generatorFunction) == "table" and generatorFunction.prepare then
        generatorFunction.prepare(ast)
        generatorFunction = generatorFunction.generateName
    end

    if #self.VarNamePrefix > 0 and not self.unparser:isValidIdentifier(self.VarNamePrefix) then
        logger:error('Invalid Prefix "%s" for Lua Version "%s".', self.VarNamePrefix, self.LuaVersion)
    end

    ast.globalScope:renameVariables({
        Keywords = self.conventions.Keywords,
        generateName = generatorFunction,
        prefix = self.VarNamePrefix
    })

    logger:info("Renaming Done.")
end

return Pipeline
