import pl_build.core as pl
from pathlib import PurePath

class plLinuxHelper:

    def __init__(self):
        self.buffer = ''
        self.indent = 0

    def set_indent(self, indent):
        self.indent = indent

    def write_file(self, file_path):
        with open(file_path, "w") as file:
            file.write(self.buffer)

    def add_line(self, line):
        self.buffer += ' ' * self.indent + line + '\n'

    def add_raw(self, text):
        self.buffer += text
        
    def add_spacing(self, count = 1):
        self.buffer += '\n' * count

    def add_title(self, title):
        line_length = 80
        padding = (line_length  - 2 - len(title)) / 2
        self.buffer += "# " + "#" * line_length + "\n"
        self.buffer += "# #" + " " * int(padding) + title + " " * int(padding + 0.5) + "#" + "\n"
        self.buffer += ("# " + "#" * line_length) + "\n"

    def add_sub_title(self, title):
        line_length = 80
        padding = (line_length  - 2 - len(title)) / 2
        self.buffer += "#" + "~" * int(padding) + " " + title + " " + "~" * int(padding + 0.5) + "\n"

    def add_comment(self, comment):
        self.buffer += ' ' * self.indent + '# ' + comment + '\n'
        
    def print_line(self, text):
        self.buffer += ' ' * self.indent + 'echo ' + text + '\n'

    def print_space(self):
        self.buffer += ' ' * self.indent + 'echo\n'
        
    def create_directory(self, directory):
        self.buffer += ' ' * self.indent + 'mkdir -p "' + directory + '"\n'

    def delete_file(self, file):
        self.buffer += ' ' * self.indent + 'rm -f ' + file + '\n'

def generate_build(name, user_options = None):

    platform = "Linux"
    compiler = "gcc"

    data = pl.get_script_data()

    # retrieve settings supported by this platform/compiler & add
    # default extensions if the user did not
    platform_settings = []
    for settings in data.current_settings:
        if settings.platform_name == platform and settings.name == compiler:
            if settings.output_binary_extension is None:
                if settings.target_type == pl.TargetType.EXECUTABLE:
                    settings.output_binary_extension = ""
                elif settings.target_type == pl.TargetType.DYNAMIC_LIBRARY:
                    settings.output_binary_extension = ".so"
                elif settings.target_type == pl.TargetType.STATIC_LIBRARY:
                    settings.output_binary_extension = ".a"
            platform_settings.append(settings)

    helper = plLinuxHelper()

    hot_reload = False

    ###############################################################################
    #                                 Intro                                       #
    ###############################################################################

    helper.add_line("#!/bin/bash")
    helper.add_spacing()
    helper.add_comment("Auto Generated by:")
    helper.add_comment('"pl_build.py" version: ' + data.version)

    helper.add_spacing()
    helper.add_comment("Project: " + data.project_name)
    helper.add_spacing()

    helper.add_title("Development Setup")
    helper.add_spacing()

    helper.add_comment("colors")
    helper.add_line("BOLD=$'\\e[0;1m'")
    helper.add_line("RED=$'\\e[0;31m'")
    helper.add_line("RED_BG=$'\\e[0;41m'")
    helper.add_line("GREEN=$'\\e[0;32m'")
    helper.add_line("GREEN_BG=$'\\e[0;42m'")
    helper.add_line("CYAN=$'\\e[0;36m'")
    helper.add_line("MAGENTA=$'\\e[0;35m'")
    helper.add_line("YELLOW=$'\\e[0;33m'")
    helper.add_line("WHITE=$'\\e[0;97m'")
    helper.add_line("NC=$'\\e[0m'")
    helper.add_spacing()

    helper.add_comment('find directory of this script')
    helper.add_line("SOURCE=${BASH_SOURCE[0]}")
    helper.add_line('while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink')
    helper.add_line('  DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )')
    helper.add_line('  SOURCE=$(readlink "$SOURCE")')
    helper.add_line('  [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located')
    helper.add_line('done')
    helper.add_line('DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )')
    helper.add_spacing()

    helper.add_comment('make script directory CWD')
    helper.add_line('pushd $DIR >/dev/null')
    helper.add_spacing()

    # set default config
    if data.registered_configurations:
        helper.add_comment("default configuration")
        helper.add_line("PL_CONFIG=" + data.registered_configurations[0])
        helper.add_spacing()

    # check command line args for config
    helper.add_comment('check command line args for configuration')
    helper.add_line('while getopts ":c:" option; do')
    helper.add_line('   case $option in')
    helper.add_line('   c) # set conf')
    helper.add_line('         PL_CONFIG=$OPTARG;;')
    helper.add_line('     \\?) # Invalid option')
    helper.add_line('         echo "Error: Invalid option"')
    helper.add_line('         exit;;')
    helper.add_line('   esac')
    helper.add_line('done')
    helper.add_spacing()

    # if _context.pre_build_step is not None:
    #     helper.add_line(_context.pre_build_step)
    #     helper.add_spacing()

    for register_config in data.registered_configurations:

        # filter this config only settings
        config_only_settings = []
        for settings in platform_settings:
            if settings.config_name == register_config:
                config_only_settings.append(settings)

        if len(config_only_settings) == 0:
            continue

        # find hot reload target
        if data.reload_target_name is not None:
            hot_reload = True

        helper.add_title("configuration | " + register_config)
        helper.add_spacing()

        helper.add_line('if [[ "$PL_CONFIG" == "' + register_config + '" ]]; then')
        helper.add_spacing()

        output_dirs = set()
        for settings in config_only_settings:
            output_dirs.add(settings.output_directory)

        # create output directories
        helper.add_comment("create output directory(s)")
        for dir in output_dirs:
            helper.create_directory(dir)
        helper.add_spacing()

        lock_files = set()
        for settings in config_only_settings:
            lock_files.add(settings.lock_file)
        helper.add_comment("create lock file(s)")
        for lock_file in lock_files:
            helper.add_line('echo LOCKING > "' + settings.output_directory + '/' + lock_file + '"')
        helper.add_spacing()

        if hot_reload:
            helper.add_comment('check if this is a reload')
            helper.add_line('PL_HOT_RELOAD_STATUS=0')
            helper.add_spacing()

            helper.add_comment("# let user know if hot reloading")
            helper.add_line('if pidof -x "' + PurePath(data.reload_target_name).stem + '" -o $$ >/dev/null;then')
            helper.set_indent(4)
            helper.add_line('PL_HOT_RELOAD_STATUS=1')
            helper.print_space()
            helper.print_line('echo ${BOLD}${WHITE}${RED_BG}--------${GREEN_BG} HOT RELOADING ${RED_BG}--------${NC}')
            helper.print_line('echo')
            helper.set_indent(0)
            helper.add_line('else')
            helper.set_indent(4)
            helper.add_comment('cleanup binaries if not hot reloading')
            helper.add_line('PL_HOT_RELOAD_STATUS=0')

        # delete old binaries & files
        for settings in config_only_settings:
            if settings.source_files:
                if settings.name == compiler:
                    if settings.target_type == pl.TargetType.DYNAMIC_LIBRARY:
                        helper.delete_file(settings.output_directory + '/' + settings.output_binary + settings.output_binary_extension)
                        helper.delete_file(settings.output_directory + '/' + settings.output_binary + '_*' + settings.output_binary_extension)
                    elif settings.target_type == pl.TargetType.EXECUTABLE:
                        helper.delete_file(settings.output_directory + '/' + settings.output_binary + settings.output_binary_extension)
                    elif settings.target_type == pl.TargetType.STATIC_LIBRARY:
                        helper.delete_file(settings.output_directory + '/' + settings.output_binary + settings.output_binary_extension)

        helper.add_spacing()
        helper.set_indent(0)
        if hot_reload:
            helper.add_spacing()
            helper.add_line("fi")

        # other targets
        for settings in config_only_settings:
            helper.add_sub_title(settings.target_name + " | " + register_config)
            helper.add_spacing()

            if not settings.reloadable and hot_reload:
                helper.add_comment('skip during hot reload')
                helper.add_line('if [ $PL_HOT_RELOAD_STATUS -ne 1 ]; then')
                helper.add_spacing()

            if settings.pre_build_step is not None:
                helper.add_line(settings.pre_build_step)
                helper.add_spacing()

            helper.add_line("PL_RESULT=${BOLD}${GREEN}Successful.${NC}")
            helper.add_raw('PL_DEFINES="')
            for define in settings.definitions:
                helper.add_raw('-D' + define + " ")
            helper.add_raw('"\n')

            helper.add_raw('PL_INCLUDE_DIRECTORIES="')
            for include in settings.include_directories:
                helper.add_raw('-I' + include + ' ')
            helper.add_raw('"\n')

            helper.add_raw('PL_LINK_DIRECTORIES="')
            for link in settings.link_directories:
                helper.add_raw('-L' + link + ' ')
            helper.add_raw('"\n')

            helper.add_raw('PL_COMPILER_FLAGS="')
            for flag in settings.compiler_flags:
                helper.add_raw(flag + ' ')
            helper.add_raw('"\n')

            helper.add_raw('PL_LINKER_FLAGS="')
            for flag in settings.linker_flags:
                helper.add_raw(flag + ' ')
            helper.add_raw('"\n')

            helper.add_raw('PL_STATIC_LINK_LIBRARIES="')
            for link in settings.static_link_libraries:
                helper.add_raw('-l:' + link + '.a ')
            helper.add_raw('"\n')

            helper.add_raw('PL_DYNAMIC_LINK_LIBRARIES="')
            for link in settings.dynamic_link_libraries:
                helper.add_raw('-l' + link + ' ')
            helper.add_raw('"\n')

            if settings.target_type == pl.TargetType.STATIC_LIBRARY:
                helper.add_comment('# run compiler only')
                helper.print_space()
                helper.print_line('${YELLOW}Step: ' + settings.target_name +'${NC}')
                helper.print_line('${YELLOW}~~~~~~~~~~~~~~~~~~~${NC}')
                helper.print_line('${CYAN}Compiling...${NC}')
                helper.add_spacing()
            
                helper.add_comment('each file must be compiled separately')
                for source in settings.source_files:
                    source_as_path = PurePath(source)
                    helper.add_line('gcc -c $PL_INCLUDE_DIRECTORIES $PL_DEFINES $PL_COMPILER_FLAGS ' + source + ' -o "./' + settings.output_directory + '/' + source_as_path.stem + '.o"')
                helper.add_spacing()
                helper.add_comment('combine object files into a static lib')
                helper.add_line('ar rcs ./' + settings.output_directory + '/' + settings.output_binary + '.a ./' + settings.output_directory + '/*.o')
                helper.add_line('rm ./' + settings.output_directory + '/*.o')
                helper.add_spacing()

            elif settings.target_type == pl.TargetType.DYNAMIC_LIBRARY:
                helper.add_raw('PL_SOURCES="')
                for source in settings.source_files:
                    helper.add_raw(source + ' ')
                helper.add_raw('"\n')
                helper.add_spacing()

                helper.add_comment('run compiler (and linker)')
                helper.print_space()
                helper.print_line('${YELLOW}Step: ' + settings.target_name +'${NC}')
                helper.print_line('${YELLOW}~~~~~~~~~~~~~~~~~~~${NC}')
                helper.print_line('${CYAN}Compiling and Linking...${NC}')
                helper.add_line('gcc -shared $PL_SOURCES $PL_INCLUDE_DIRECTORIES $PL_DEFINES $PL_COMPILER_FLAGS $PL_INCLUDE_DIRECTORIES $PL_LINK_DIRECTORIES $PL_LINKER_FLAGS $PL_STATIC_LINK_LIBRARIES $PL_DYNAMIC_LINK_LIBRARIES -o "./' + settings.output_directory + '/' + settings.output_binary + settings.output_binary_extension +'"')
                helper.add_spacing()

            elif settings.target_type == pl.TargetType.EXECUTABLE:
                helper.add_raw('PL_SOURCES="')
                for source in settings.source_files:
                    helper.add_raw(source + ' ')
                helper.add_raw('"\n')
                helper.add_spacing()

                helper.add_comment('run compiler (and linker)')
                helper.print_space()
                helper.print_line('${YELLOW}Step: ' + settings.target_name +'${NC}')
                helper.print_line('${YELLOW}~~~~~~~~~~~~~~~~~~~${NC}')
                helper.print_line('${CYAN}Compiling and Linking...${NC}')
                helper.add_line('gcc $PL_SOURCES $PL_INCLUDE_DIRECTORIES $PL_DEFINES $PL_COMPILER_FLAGS $PL_INCLUDE_DIRECTORIES $PL_LINK_DIRECTORIES $PL_LINKER_FLAGS $PL_STATIC_LINK_LIBRARIES $PL_DYNAMIC_LINK_LIBRARIES -o "./' + settings.output_directory + '/' + settings.output_binary + settings.output_binary_extension +'"')
                helper.add_spacing()

            # check build status
            helper.add_comment("check build status")
            helper.add_line("if [ $? -ne 0 ]")
            helper.add_line("then")
            helper.add_line("    PL_RESULT=${BOLD}${RED}Failed.${NC}")
            helper.add_line("fi")
            helper.add_spacing()

            # print results
            helper.add_comment("print results")
            helper.print_line("${CYAN}Results: ${NC} ${PL_RESULT}")
            helper.print_line("${CYAN}~~~~~~~~~~~~~~~~~~~~~~${NC}")
            helper.add_spacing()

            if settings.post_build_step is not None:
                helper.add_line(settings.post_build_step)
                helper.add_spacing()

            if not settings.reloadable and hot_reload:
                helper.add_comment("hot reload skip")
                helper.add_line("fi")
                helper.add_spacing()

        helper.add_comment("delete lock file(s)")
        for lock_file in lock_files:
            helper.delete_file(settings.output_directory + '/' + lock_file)
        helper.add_spacing()

        # end of config
        helper.add_comment('~' * 40)
        helper.add_comment('end of ' + register_config)
        helper.add_line('fi')
        helper.add_spacing()

    helper.add_spacing()
    # if _context.post_build_step is not None:
    #     helper.add_line(_context.post_build_step)
    #     helper.add_spacing()
    helper.add_comment('return CWD to previous CWD')
    helper.add_line('popd >/dev/null')

    helper.write_file(name)